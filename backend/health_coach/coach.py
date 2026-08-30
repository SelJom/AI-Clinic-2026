from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone

from . import storage
from .guidelines import GuidelineStore, get_default_store
from .llm_backends import ConversationBackend, CoachContext, get_default_backend
from .models import ChatTurn, DailyFeatures, Recommendation, RiskAssessment

TREND_WINDOW_DAYS = 14


def _format_trend(
    features: list[DailyFeatures], risk_by_day: dict[date, str] | None = None
) -> list[str]:
    """Annotates each day with its actual computed risk level when it wasn't
    "normal". Observed live: asked directly about a day that was a real
    escalate-level spike, the model answered "no concerns, just a normal
    day" - the number it gave was correct, but nothing tied that specific
    date to what the rule engine had already determined about it, so the
    model's own read of "does this look concerning" won by default. Putting
    the flag inline, next to the number, means it doesn't depend on the
    model correctly cross-referencing a separate guideline snippet against
    a date - it's part of the same grounded fact."""
    risk_by_day = risk_by_day or {}
    lines = []
    for f in features:
        rhr = f"{f.resting_hr:.0f} bpm" if f.resting_hr is not None else "no data"
        sleep = f"{f.sleep_hours:.1f}h" if f.sleep_hours is not None else "no data"
        steps = f"{f.steps}" if f.steps is not None else "no data"
        line = f"{f.day.isoformat()}: resting HR {rhr}, sleep {sleep}, steps {steps}"
        level = risk_by_day.get(f.day)
        if level and level != "normal":
            line += f" [FLAGGED {level.upper()} that day by the rule engine - never call this day normal or no-concern]"
        lines.append(line)
    return lines


# (label, attribute, unit, decimal places)
_TREND_METRICS = [
    ("resting HR", "resting_hr", "bpm", 0),
    ("sleep", "sleep_hours", "h", 1),
    ("steps", "steps", "", 0),
]


def _compute_trend_stats(features: list[DailyFeatures]) -> list[str]:
    """Precomputes average/lowest/highest per metric in Python. Small local
    LLMs are unreliable at exact arithmetic over a list of numbers in a
    prompt (observed: asked for an average sleep figure, the model returned
    an unfilled "[total sleep hours]" placeholder instead of a number) - so
    for aggregate questions, hand the model an already-correct figure to
    relay instead of asking it to compute one itself."""
    lines = []
    for label, attr, unit, digits in _TREND_METRICS:
        points = [(f.day, getattr(f, attr)) for f in features if getattr(f, attr) is not None]
        if not points:
            continue
        values = [v for _, v in points]
        avg = sum(values) / len(values)
        low_day, low_val = min(points, key=lambda p: p[1])
        high_day, high_val = max(points, key=lambda p: p[1])
        lines.append(
            f"{label} over {len(points)} days: average {avg:.{digits}f}{unit}, "
            f"lowest {low_val:.{digits}f}{unit} on {low_day.isoformat()}, "
            f"highest {high_val:.{digits}f}{unit} on {high_day.isoformat()}"
        )
    return lines


# "How many days did X happen" is architecturally different from the average/
# lowest/highest questions _compute_trend_stats handles: the threshold is
# open-ended (any number the patient types), so it can't be precomputed in
# advance the same way. Observed live: asked "how many days did I sleep less
# than 6 hours," the model answered "three days" while citing individually
# real, grounded sleep values - the actual answer was four, it included a
# day that didn't qualify and missed two that did. Every number it stated
# was real, so the numeric-grounding check passed even though the count was
# wrong - filtering-and-counting across many values is exactly the kind of
# multi-step arithmetic small local models are unreliable at, the same
# family of problem as the average bug, just not caught by that fix.
#
# The fix here is architectural, not a bigger prompt: detect this question
# shape and answer it with an exact Python computation over the real data,
# skipping the LLM for that turn entirely - matching "sensor model first,
# LLM last" literally, not just for grounding numbers after the fact.
_HOW_MANY_DAYS_RE = re.compile(r"\bhow many (?:days|times)\b", re.IGNORECASE)
_COUNT_METRICS = [
    ("resting_hr", re.compile(r"heart rate|resting hr\b|\bhr\b|\bbpm\b", re.IGNORECASE), "resting HR", "bpm", 0),
    ("sleep_hours", re.compile(r"\bslept?\b|\bsleep\b", re.IGNORECASE), "sleep", "h", 1),
    ("steps", re.compile(r"\bsteps?\b|\bwalked\b", re.IGNORECASE), "steps", "", 0),
]
_COUNT_COMPARATORS = [
    (re.compile(r"\b(less than|fewer than|under|below)\b", re.IGNORECASE), (lambda v, t: v < t), "below"),
    (re.compile(r"\b(more than|above|over|greater than)\b", re.IGNORECASE), (lambda v, t: v > t), "above"),
    (re.compile(r"\bat least\b", re.IGNORECASE), (lambda v, t: v >= t), "at least"),
    (re.compile(r"\b(at most|no more than)\b", re.IGNORECASE), (lambda v, t: v <= t), "at most"),
]
_COUNT_NUMBER_RE = re.compile(r"\d+(?:\.\d+)?")


def _try_answer_count_question(message: str, features: list[DailyFeatures]) -> str | None:
    """Returns an exact deterministic answer if `message` matches a
    "how many days was <metric> <comparator> <number>" shape, else None so
    the caller falls back to the normal LLM path unchanged. Deliberately
    narrow - a question combining this with something else, or phrased
    differently, won't match and just goes through the LLM as before."""
    if not _HOW_MANY_DAYS_RE.search(message):
        return None

    metric = next((m for m in _COUNT_METRICS if m[1].search(message)), None)
    comparator = next((c for c in _COUNT_COMPARATORS if c[0].search(message)), None)
    number_match = _COUNT_NUMBER_RE.search(message)
    if metric is None or comparator is None or number_match is None:
        return None

    attr, _pattern, label, unit, digits = metric
    _cmp_pattern, cmp_fn, cmp_label = comparator
    threshold = float(number_match.group(0))

    matches = [
        f.day for f in features
        if (v := getattr(f, attr)) is not None and cmp_fn(v, threshold)
    ]
    threshold_str = f"{threshold:.{digits}f}{unit}"
    window = f"the last {len(features)} recorded day{'s' if len(features) != 1 else ''}"

    if not matches:
        return f"Looking at {window}, your {label} was never {cmp_label} {threshold_str}."

    days_str = ", ".join(d.isoformat() for d in matches)
    return (
        f"Looking at {window}, your {label} was {cmp_label} {threshold_str} on "
        f"{len(matches)} day{'s' if len(matches) != 1 else ''}: {days_str}."
    )


# "What have my steps been each day for the past week" is a different failure
# mode again: observed live, asked this with only a single real day of
# history on record, the model invented six additional calendar dates -
# several of them in the *future* relative to "today" - and labeled them
# "no data available", rather than just listing the one real day it
# actually had. Nothing before this caught it because every individual
# number/citation in the reply was either real or an honest "no data"
# placeholder; the fabrication was in which *dates* it decided to enumerate,
# not in a number or a source name. Same fix shape as the counting bug:
# detect the question and answer from the real row set directly, so there
# is no date arithmetic for the model to get wrong.
_DAILY_BREAKDOWN_RE = re.compile(r"\b(each day|every day|per day|daily)\b", re.IGNORECASE)


def _try_answer_daily_breakdown_question(message: str, features: list[DailyFeatures]) -> str | None:
    """Returns an exact list of the real recorded days for one metric if
    `message` asks for a day-by-day breakdown, else None. Only ever lists
    days that actually exist in `features` - never pads out to a requested
    "past N days" with invented dates, so there is nothing to hallucinate
    about which calendar dates existed."""
    if not _DAILY_BREAKDOWN_RE.search(message):
        return None

    metric = next((m for m in _COUNT_METRICS if m[1].search(message)), None)
    if metric is None:
        return None

    attr, _pattern, label, unit, digits = metric
    if not features:
        return f"I don't have any recorded days yet for your {label}."

    lines = []
    for f in features:
        v = getattr(f, attr)
        lines.append(f"{f.day.isoformat()}: {f'{v:.{digits}f}{unit}' if v is not None else 'no data'}")

    return (
        f"Here's your {label} for each of the {len(features)} day{'s' if len(features) != 1 else ''} "
        f"I actually have on record (I don't have anything before that):\n" + "\n".join(lines)
    )


class CoachAgent:
    def __init__(
        self,
        backend: ConversationBackend | None = None,
        guideline_store: GuidelineStore | None = None,
    ):
        self.backend = backend or get_default_backend()
        self.guideline_store = guideline_store or get_default_store()

    def handle_message(
        self,
        patient_id: str,
        message: str,
        latest_assessment: RiskAssessment | None = None,
        latest_recommendations: list[Recommendation] | None = None,
    ) -> str:
        latest_assessment = latest_assessment or storage.load_latest_risk_assessment(patient_id)
        recommendations = latest_recommendations or []

        recommendation_summaries = [r.body for r in recommendations]
        guideline_snippets = [
            f"[{c.evidence_level or '?'},{c.recommendation_grade or '?'}] {c.text[:220]}"
            for r in recommendations
            for c in r.citations
        ]
        if not guideline_snippets:
            retrieved = self.guideline_store.retrieve(message, k=2)
            guideline_snippets = [
                f"[{s.evidence_level or '?'},{s.recommendation_grade or '?'}] {s.text[:220]}"
                for s in retrieved
            ]

        recent_chat = [(t.role, t.text) for t in storage.load_chat_history(patient_id, limit=6)]

        reference_day = latest_assessment.day if latest_assessment else date.today()
        recent_features = storage.load_recent_daily_features(
            patient_id, before=reference_day + timedelta(days=1), limit_days=TREND_WINDOW_DAYS
        )
        recent_assessments = storage.load_recent_risk_assessments(
            patient_id, before=reference_day + timedelta(days=1), limit_days=TREND_WINDOW_DAYS
        )
        risk_by_day = {a.day: a.level.value for a in recent_assessments}

        context = CoachContext(
            patient_id=patient_id,
            risk_level=latest_assessment.level.value if latest_assessment else "unknown",
            recommendation_summaries=recommendation_summaries,
            guideline_snippets=guideline_snippets,
            escalate=bool(latest_assessment and latest_assessment.escalate),
            recent_chat=recent_chat,
            recent_trend=_format_trend(recent_features, risk_by_day),
            trend_stats=_compute_trend_stats(recent_features),
        )

        deterministic_reply = _try_answer_count_question(
            message, recent_features
        ) or _try_answer_daily_breakdown_question(message, recent_features)
        reply = deterministic_reply if deterministic_reply is not None else self.backend.generate(message, context)

        now = datetime.now(timezone.utc)
        storage.save_chat_turn(ChatTurn(patient_id, "user", message, now))
        storage.save_chat_turn(ChatTurn(patient_id, "coach", reply, now))
        return reply

    def explain_last_recommendation(self, patient_id: str) -> str:
        assessment = storage.load_latest_risk_assessment(patient_id)
        if assessment is None:
            return "I don't have any assessment for you yet - sync some data first."
        if not assessment.hits:
            return "Nothing was flagged: your recent heart rate, sleep, and activity are all close to your own baseline."

        lines = [f"On {assessment.day}, I flagged the following against your personal baseline:"]
        for hit in assessment.hits:
            lines.append(f"• {hit.description} (rule: {hit.rule_id}, level: {hit.risk_level.value})")
        return "\n".join(lines)
