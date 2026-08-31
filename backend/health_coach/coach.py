from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone

from . import storage
from .activity import classify_activity_level
from .guidelines import GuidelineStore, get_default_store
from .llm_backends import ConversationBackend, CoachContext, get_default_backend
from .models import ChatTurn, DailyFeatures, Recommendation, RiskAssessment
from .rules import RULES, build_recommendations

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


# "What's my average steps per day in the past 7 days" is a THIRD failure
# shape, found live on a real phone: it contains "per day", which matched
# _DAILY_BREAKDOWN_RE below, so the full 13-day raw dump won and the actual
# ask - an average, windowed to 7 days - was silently ignored. "Average"
# must be checked first and win over "per day"/"each day" phrasing, and the
# window (if a day count is given) has to be a real slice of the most
# recent rows, not the fixed-size trend_stats window computed once for the
# whole conversation.
_AVERAGE_RE = re.compile(r"\b(average|avg|mean)\b", re.IGNORECASE)
_LAST_N_DAYS_RE = re.compile(r"\b(?:past|last)\s+(\d+)\s+days?\b", re.IGNORECASE)


def _try_answer_windowed_average_question(message: str, features: list[DailyFeatures]) -> str | None:
    """Returns an exact average for a metric, optionally windowed to the
    last N days if the message names a day count - real slice of the real
    rows, not the whole conversation's fixed trend window. Checked before
    _try_answer_daily_breakdown_question so "average ... per day" doesn't
    get swallowed by the "per day" dump."""
    if not _AVERAGE_RE.search(message):
        return None

    metric = next((m for m in _COUNT_METRICS if m[1].search(message)), None)
    if metric is None:
        return None

    attr, _pattern, label, unit, digits = metric
    n_match = _LAST_N_DAYS_RE.search(message)
    caveat = ""
    if n_match:
        n = int(n_match.group(1))
        if n < len(features):
            window = features[-n:]
        else:
            window = features
            if n > len(features):
                caveat = f" (only {len(features)} day{'s' if len(features) != 1 else ''} actually on record, not {n})"
    else:
        window = features

    values = [getattr(f, attr) for f in window if getattr(f, attr) is not None]
    if not values:
        return f"I don't have any recorded {label} data to average."

    avg = sum(values) / len(values)
    window_desc = f"the last {len(window)} recorded day{'s' if len(window) != 1 else ''}{caveat}"
    return f"Looking at {window_desc}, your average {label} was {avg:.{digits}f}{unit}."


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


# "How many steps should I aim for" and its variants used to fail in two
# different ways, both observed live: the model would either state a made-up
# precise figure (which ground_reply correctly caught and replaced,
# producing an awkward "aim for at least a specific figure I don't have
# handy a day" mid-sentence) or, once burned by that, avoid giving any
# number at all even when asked directly. Neither is really the model's
# fault - the real guideline corpus (NCI PDQ supportive-care extracts) has
# zero mentions of "steps" anywhere, and TF-IDF retrieval on a query this
# short/generic doesn't reliably surface the two step-guidance entries added
# to the corpus for this either (confirmed directly: they don't make the
# retrieval's top-2 cutoff for this exact phrasing). Bypassing the LLM
# entirely for this specific, very common question means a consistent,
# honestly-sourced answer every time, instead of leaving it to chance.
_STEP_GOAL_RE = re.compile(
    # Deliberately does NOT match bare "how many steps" (that's a factual
    # lookup, e.g. "how many steps did I walk today" - handled elsewhere/by
    # the LLM from real trend data). Every alternative here requires a
    # goal-seeking word ("should", "aim", "target", "goal", "recommended")
    # so this only fires for "what should my number be", not "what was it".
    r"(how many steps should i|"
    r"how (much|many) should i (aim|walk|do|take)|"
    r"(step|activity) (goal|target)|"
    r"recommended (steps?|number of steps?)|"
    r"good (number|amount) of steps?)",
    re.IGNORECASE,
)


def _try_answer_step_goal_question(message: str, features: list[DailyFeatures]) -> str | None:
    if not _STEP_GOAL_RE.search(message):
        return None

    today_steps = next((f.steps for f in reversed(features) if f.steps is not None), None)
    comparison = f" For reference, you're at {today_steps} steps today." if today_steps is not None else ""

    return (
        "There's no single official step-count target - exercise guidelines are given in "
        "minutes of activity per week rather than a fixed step count. The general recommendation "
        "for adults is 150-300 minutes of moderate activity a week (or 75-150 minutes vigorous), "
        "plus strength training at least twice a week, adjusted for how you're feeling and your "
        "care team's guidance if you're in cancer treatment. As rough step-count context: under "
        "5,000 a day is considered sedentary, 7,000-10,000 is associated with general health "
        "benefits, and 10,000-12,000+ is more of a higher-fitness/weight-loss range - the "
        "commonly quoted \"10,000 steps\" as a universal target isn't actually from a clinical "
        "guideline, it started as 1960s pedometer marketing." + comparison
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

        deterministic_reply = (
            _try_answer_count_question(message, recent_features)
            or _try_answer_windowed_average_question(message, recent_features)
            or _try_answer_daily_breakdown_question(message, recent_features)
            or _try_answer_step_goal_question(message, recent_features)
        )
        reply = deterministic_reply if deterministic_reply is not None else self.backend.generate(message, context)

        now = datetime.now(timezone.utc)
        storage.save_chat_turn(ChatTurn(patient_id, "user", message, now))
        storage.save_chat_turn(ChatTurn(patient_id, "coach", reply, now))
        return reply

    def build_activity_summary(self, patient_id: str) -> dict | None:
        """AI-generated, but fully grounded, explanation of today's activity
        level. The label is never up to the model - see
        activity.classify_activity_level(); only the natural-language "why"
        is ever generated, through the exact same backend.generate() ->
        ground_reply/ground_citations pipeline every chat reply goes
        through, so a fabricated number or citation here is caught the
        same way it would be in chat."""
        today = storage.load_recent_daily_features(
            patient_id, before=date.today() + timedelta(days=1), limit_days=1
        )
        if not today:
            return None
        features = today[-1]

        assessment = storage.load_risk_assessment_for_day(patient_id, features.day)
        level = classify_activity_level(features, assessment)

        recommendations = (
            build_recommendations(features, assessment, RULES, self.guideline_store)
            if assessment is not None
            else []
        )
        guideline_snippets = [
            f"[{c.evidence_level or '?'},{c.recommendation_grade or '?'}] {c.text[:220]}"
            for r in recommendations
            for c in r.citations
        ]

        recent_features = storage.load_recent_daily_features(
            patient_id, before=features.day + timedelta(days=1), limit_days=TREND_WINDOW_DAYS
        )

        context = CoachContext(
            patient_id=patient_id,
            risk_level=assessment.level.value if assessment else "unknown",
            recommendation_summaries=[r.body for r in recommendations],
            guideline_snippets=guideline_snippets,
            escalate=bool(assessment and assessment.escalate),
            recent_chat=[],
            recent_trend=_format_trend(recent_features),
            trend_stats=_compute_trend_stats(recent_features),
        )

        # Real bug this fixed: asked at 13:43 with 0 steps so far, the model
        # told the patient to "aim for movement tomorrow" - completely
        # ignoring that most of today was still ahead of them. The rule
        # engine's tier (Low/Fair/etc.) is correctly based on steps-so-far
        # regardless of the hour, but the model's PHRASING wasn't - it needs
        # to know what time it actually is to avoid writing off a day that
        # isn't over yet.
        now = datetime.now()
        time_context = ""
        if features.day == now.date():
            time_context = (
                f" It's currently {now.strftime('%H:%M')} today, so factor that into how you "
                f"phrase this: if it's still morning or afternoon, there's plenty of the day "
                f"left - don't suggest waiting until tomorrow, suggest something for later "
                f"today instead (or just note it's still early and numbers may well change by "
                f"tonight). Only frame it as a tomorrow thing if it's already evening (after "
                f"around 8pm) and today is genuinely almost over."
            )

        prompt = (
            f"Today's overall activity level has already been classified as '{level.label}' "
            f"by the rule engine - your only job is to explain why, warmly, in 2-3 sentences, "
            f"using ONLY today's real numbers (resting HR {features.resting_hr}, sleep "
            f"{features.sleep_hours}h, steps {features.steps}, calories {features.calories})."
            f"{time_context} Do not question or restate the classification itself, and do not "
            f"invent any number not listed here."
        )
        summary = self.backend.generate(prompt, context)

        return {
            "day": str(features.day),
            "level": level.label,
            "tier": level.tier,
            "summary": summary,
            "resting_hr": features.resting_hr,
            "sleep_hours": features.sleep_hours,
            "steps": features.steps,
            "calories": features.calories,
        }

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
