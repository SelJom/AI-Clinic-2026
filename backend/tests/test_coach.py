from datetime import date, timedelta

import pytest

from health_coach import config, storage
from health_coach.coach import (
    CoachAgent,
    _compute_trend_stats,
    _format_trend,
    _try_answer_count_question,
    _try_answer_daily_breakdown_question,
)
from health_coach.llm_backends import (
    ConversationBackend,
    CoachContext,
    OllamaBackend,
    ollama_is_reachable,
)
from health_coach.models import DailyFeatures, RiskAssessment, RiskLevel


class RecordingBackend(ConversationBackend):
    """Fake backend that just remembers the context it was given, so tests
    can assert on what CoachAgent builds without needing a real LLM."""

    name = "recording"

    def __init__(self):
        self.last_context: CoachContext | None = None

    def generate(self, user_message: str, context: CoachContext) -> str:
        self.last_context = context
        return "ok"


class _EmptyGuidelineStore:
    def retrieve(self, query: str, k: int = 3, min_score: float = 0.02):
        return []


def _seed_trend(patient_id="p1"):
    base = date(2026, 1, 1)
    values = [
        (68.0, 7.2, 5400),
        (71.0, 5.1, 3200),
        (69.0, 6.8, 6100),
    ]
    for i, (hr, sleep, steps) in enumerate(values):
        storage.save_daily_features(
            DailyFeatures(patient_id, base + timedelta(days=i), resting_hr=hr, sleep_hours=sleep, steps=steps)
        )
    assessment = RiskAssessment(patient_id=patient_id, day=base + timedelta(days=2), level=RiskLevel.NORMAL)
    storage.save_risk_assessment(assessment)
    return assessment


def test_format_trend_handles_missing_signals():
    features = [
        DailyFeatures("p1", date(2026, 1, 1), resting_hr=70.0, sleep_hours=7.5, steps=6000),
        DailyFeatures("p1", date(2026, 1, 2), resting_hr=None, sleep_hours=None, steps=None),
    ]
    lines = _format_trend(features)
    assert lines[0] == "2026-01-01: resting HR 70 bpm, sleep 7.5h, steps 6000"
    assert lines[1] == "2026-01-02: resting HR no data, sleep no data, steps no data"


def test_format_trend_flags_non_normal_days():
    features = [
        DailyFeatures("p1", date(2026, 1, 1), resting_hr=70.0, sleep_hours=7.5, steps=6000),
        DailyFeatures("p1", date(2026, 1, 2), resting_hr=128.0, sleep_hours=8.0, steps=9000),
    ]
    risk_by_day = {date(2026, 1, 1): "normal", date(2026, 1, 2): "escalate"}
    lines = _format_trend(features, risk_by_day)
    assert "[FLAGGED" not in lines[0]
    assert "[FLAGGED ESCALATE" in lines[1]
    assert "never call this day normal" in lines[1]


def test_format_trend_without_risk_by_day_has_no_flags():
    features = [DailyFeatures("p1", date(2026, 1, 1), resting_hr=128.0, sleep_hours=8.0, steps=9000)]
    lines = _format_trend(features)
    assert "[FLAGGED" not in lines[0]


def test_handle_message_answers_count_question_without_calling_backend(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    storage.init_db()
    _seed_trend()  # sleep hours: 7.2, 5.1, 6.8 across 3 days

    backend = RecordingBackend()
    agent = CoachAgent(backend=backend, guideline_store=_EmptyGuidelineStore())

    reply = agent.handle_message("p1", "How many days did I sleep less than 6 hours?")

    assert backend.last_context is None  # never invoked - answered deterministically
    assert "1 day" in reply
    assert "2026-01-02" in reply


def test_handle_message_falls_through_to_backend_for_non_count_questions(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    storage.init_db()
    _seed_trend()

    backend = RecordingBackend()
    agent = CoachAgent(backend=backend, guideline_store=_EmptyGuidelineStore())

    agent.handle_message("p1", "How can I sleep better?")

    assert backend.last_context is not None  # normal LLM path used


def test_handle_message_passes_real_trend_to_backend(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    storage.init_db()
    _seed_trend()

    backend = RecordingBackend()
    agent = CoachAgent(backend=backend, guideline_store=_EmptyGuidelineStore())

    agent.handle_message("p1", "What is the least I slept?")

    assert backend.last_context is not None
    assert len(backend.last_context.recent_trend) == 3
    assert "5.1h" in backend.last_context.recent_trend[1]
    assert any("sleep" in s for s in backend.last_context.trend_stats)


# --- _try_answer_count_question: deterministic bypass for counting questions
# Regression coverage for a real live failure: the model miscounted "days
# below 6h" while citing individually-real numbers. These answers are exact
# Python computations, not LLM output, so there's nothing to hallucinate.

def _sleep_features():
    base = date(2026, 8, 19)
    values = [8.8, 5.1, 6.0, 5.5, 7.4, 8.8, 8.5, 6.3, 7.1, 5.8, 8.3, 5.9]
    return [DailyFeatures("p1", base + timedelta(days=i), sleep_hours=v) for i, v in enumerate(values)]


def test_count_question_gets_the_actual_right_answer():
    # This is the exact real failure: the model said "three days" for
    # sleep < 6h; the true answer is four (08-20, 08-22, 08-28, 08-30).
    answer = _try_answer_count_question("How many days did I sleep less than 6 hours?", _sleep_features())
    assert answer is not None
    assert "4 days" in answer
    assert "2026-08-20" in answer
    assert "2026-08-22" in answer
    assert "2026-08-28" in answer
    assert "2026-08-30" in answer
    assert "2026-08-26" not in answer  # 6.3h - doesn't qualify, the model wrongly included this one


def test_count_question_handles_above_threshold():
    features = [
        DailyFeatures("p1", date(2026, 1, 1), resting_hr=70.0),
        DailyFeatures("p1", date(2026, 1, 2), resting_hr=128.0),
    ]
    answer = _try_answer_count_question("How many days was my heart rate above 100?", features)
    assert answer is not None
    assert "1 day" in answer
    assert "2026-01-02" in answer
    assert "2026-01-01" not in answer


def test_count_question_handles_zero_matches():
    features = [DailyFeatures("p1", date(2026, 1, 1), steps=8000)]
    answer = _try_answer_count_question("How many days did I walk more than 20000 steps?", features)
    assert answer is not None
    assert "never" in answer


def test_count_question_returns_none_for_non_matching_message():
    features = _sleep_features()
    assert _try_answer_count_question("What's the weather like?", features) is None
    assert _try_answer_count_question("How can I sleep better?", features) is None
    assert _try_answer_count_question("What's my average sleep?", features) is None


# --- _try_answer_daily_breakdown_question: no invented dates -----------
# Regression coverage for a real live failure: asked "what have been my
# steps each day for the past seven days" with only one real recorded day,
# the model invented six more calendar dates - several in the *future*
# relative to "today" - labeled "no data available", instead of just
# listing the single real day it actually had.

def test_daily_breakdown_lists_only_real_days_never_invents_future_dates():
    features = [DailyFeatures("p1", date(2026, 8, 30), steps=8247)]
    answer = _try_answer_daily_breakdown_question(
        "Could you tell me what have been my steps each day for the past seven days?", features
    )
    assert answer is not None
    assert "2026-08-30: 8247" in answer
    assert "1 day" in answer
    # The exact fabrication observed live: dates after the only real day.
    assert "2026-08-31" not in answer
    assert "2026-09-01" not in answer


def test_daily_breakdown_reports_gaps_within_real_days_as_no_data():
    features = [
        DailyFeatures("p1", date(2026, 8, 29), steps=None),
        DailyFeatures("p1", date(2026, 8, 30), steps=8247),
    ]
    answer = _try_answer_daily_breakdown_question("What have my steps been each day?", features)
    assert "2026-08-29: no data" in answer
    assert "2026-08-30: 8247" in answer


def test_daily_breakdown_handles_no_recorded_days():
    answer = _try_answer_daily_breakdown_question("What have my steps been each day?", [])
    assert answer == "I don't have any recorded days yet for your steps."


def test_daily_breakdown_returns_none_without_daily_phrasing():
    features = [DailyFeatures("p1", date(2026, 8, 30), steps=8247)]
    assert _try_answer_daily_breakdown_question("What's my average steps?", features) is None
    assert _try_answer_daily_breakdown_question("How can I improve my steps?", features) is None


def test_handle_message_flags_non_normal_days_in_trend(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    storage.init_db()
    base = date(2026, 1, 1)
    storage.save_daily_features(DailyFeatures("p1", base, resting_hr=70.0, sleep_hours=7.0, steps=6000))
    storage.save_risk_assessment(RiskAssessment(patient_id="p1", day=base, level=RiskLevel.NORMAL))
    storage.save_daily_features(DailyFeatures("p1", base + timedelta(days=1), resting_hr=128.0, sleep_hours=8.0, steps=9000))
    storage.save_risk_assessment(RiskAssessment(patient_id="p1", day=base + timedelta(days=1), level=RiskLevel.ESCALATE))

    backend = RecordingBackend()
    agent = CoachAgent(backend=backend, guideline_store=_EmptyGuidelineStore())
    agent.handle_message("p1", "how am I doing?", latest_assessment=RiskAssessment(
        patient_id="p1", day=base + timedelta(days=1), level=RiskLevel.ESCALATE
    ))

    trend = backend.last_context.recent_trend
    assert "[FLAGGED" not in trend[0]
    assert "[FLAGGED ESCALATE" in trend[1]


def test_compute_trend_stats_averages_lowest_highest():
    features = [
        DailyFeatures("p1", date(2026, 1, 1), resting_hr=68.0, sleep_hours=7.2, steps=5400),
        DailyFeatures("p1", date(2026, 1, 2), resting_hr=71.0, sleep_hours=5.1, steps=3200),
        DailyFeatures("p1", date(2026, 1, 3), resting_hr=69.0, sleep_hours=6.8, steps=6100),
    ]
    stats = _compute_trend_stats(features)
    sleep_line = next(s for s in stats if s.startswith("sleep"))

    # average of 7.2, 5.1, 6.8 = 6.366... -> 6.4h
    assert "average 6.4h" in sleep_line
    assert "lowest 5.1h on 2026-01-02" in sleep_line
    assert "highest 7.2h on 2026-01-01" in sleep_line


def test_compute_trend_stats_skips_missing_signals():
    features = [
        DailyFeatures("p1", date(2026, 1, 1), resting_hr=70.0, sleep_hours=None, steps=6000),
    ]
    stats = _compute_trend_stats(features)
    assert not any(s.startswith("sleep") for s in stats)
    assert any(s.startswith("resting HR") for s in stats)


def test_compute_trend_stats_empty_input():
    assert _compute_trend_stats([]) == []


@pytest.mark.skipif(not ollama_is_reachable(), reason="requires a local Ollama daemon")
def test_ollama_backend_uses_real_trend_data_not_fabrication():
    """Regression test for the bug documented in README: the chat used to
    invent a plausible-sounding sleep figure instead of reading the real
    trend data it was given. Asserts the correct low-sleep day (5.1h) is
    the one reported, not a hallucinated number."""
    ctx = CoachContext(
        patient_id="p1",
        risk_level="low",
        recommendation_summaries=[],
        guideline_snippets=[],
        escalate=False,
        recent_chat=[],
        recent_trend=[
            "2026-08-24: resting HR 68 bpm, sleep 7.2h, steps 5400",
            "2026-08-25: resting HR 71 bpm, sleep 5.1h, steps 3200",
            "2026-08-26: resting HR 69 bpm, sleep 6.8h, steps 6100",
        ],
        trend_stats=[
            "resting HR over 3 days: average 69bpm, lowest 68bpm on 2026-08-24, highest 71bpm on 2026-08-25",
            "sleep over 3 days: average 6.4h, lowest 5.1h on 2026-08-25, highest 7.2h on 2026-08-24",
            "steps over 3 days: average 4900, lowest 3200 on 2026-08-25, highest 6100 on 2026-08-26",
        ],
    )
    reply = OllamaBackend().generate("What is the least I slept this week, in hours?", ctx)
    assert "5.1" in reply


@pytest.mark.skipif(not ollama_is_reachable(), reason="requires a local Ollama daemon")
def test_ollama_backend_reports_precomputed_average_not_placeholder():
    """Regression test for a real failure seen in `cli demo`: asked for the
    average sleep time, the model returned an unfilled placeholder like
    "[total sleep hours]" instead of a number, because it was trying to
    average a list of decimals itself - small local models are unreliable
    at that. Asserts the model instead relays the precomputed average from
    `trend_stats` (6.4h for this fixture)."""
    ctx = CoachContext(
        patient_id="p1",
        risk_level="low",
        recommendation_summaries=[],
        guideline_snippets=[],
        escalate=False,
        recent_chat=[],
        recent_trend=[
            "2026-08-24: resting HR 68 bpm, sleep 7.2h, steps 5400",
            "2026-08-25: resting HR 71 bpm, sleep 5.1h, steps 3200",
            "2026-08-26: resting HR 69 bpm, sleep 6.8h, steps 6100",
        ],
        trend_stats=[
            "sleep over 3 days: average 6.4h, lowest 5.1h on 2026-08-25, highest 7.2h on 2026-08-24",
        ],
    )
    reply = OllamaBackend().generate("What's the average of my sleep time?", ctx)
    assert "6.4" in reply
    assert "[" not in reply


@pytest.mark.skipif(not ollama_is_reachable(), reason="requires a local Ollama daemon")
def test_ollama_backend_does_not_call_a_flagged_day_normal():
    """Regression test for a real failure found in manual testing: asked
    directly about a day that was a real ESCALATE-level heart rate spike
    (128 bpm, above the 120 bpm guideline threshold), the model answered
    "No concerns here! Just a normal day" - the number was correct but the
    conclusion was dangerously wrong, because nothing tied that specific
    date to what the rule engine had already determined about it. Asserts
    the reply doesn't claim the flagged day was normal/fine/no-concern."""
    ctx = CoachContext(
        patient_id="p1",
        risk_level="normal",
        recommendation_summaries=["Your heart rate, sleep, and activity all look consistent with your recent baseline."],
        guideline_snippets=["[1,A] Resting heart rate above 120 bpm should prompt contacting your care team promptly."],
        escalate=False,
        recent_chat=[],
        recent_trend=[
            "2026-08-28: resting HR 68 bpm, sleep 5.8h, steps 10458",
            "2026-08-29: resting HR 128 bpm, sleep 8.3h, steps 10761 "
            "[FLAGGED ESCALATE that day by the rule engine - never call this day normal or no-concern]",
            "2026-08-30: resting HR 68 bpm, sleep 5.9h, steps 3542",
        ],
    )
    reply = OllamaBackend().generate("What was my heart rate on August 29th?", ctx)
    lowered = reply.lower()
    assert "128" in reply
    assert "no concern" not in lowered
    assert "normal day" not in lowered
    assert "just a normal" not in lowered


@pytest.mark.skipif(not ollama_is_reachable(), reason="requires a local Ollama daemon")
def test_ollama_backend_strips_fabricated_organization_citation():
    """Regression test for a real failure found in manual testing: asked
    about a medication interaction, the model attributed its answer to the
    "National Comprehensive Cancer Network (NCCN)" - a real organization,
    but one that was never in guideline_snippets. It invented the citation
    from general training knowledge and presented it as if retrieved."""
    ctx = CoachContext(
        patient_id="p1",
        risk_level="normal",
        recommendation_summaries=[],
        guideline_snippets=["[1,A] Discuss any over-the-counter medication with your care team before use during treatment."],
        escalate=False,
        recent_chat=[],
    )
    reply = OllamaBackend().generate("Can I take ibuprofen with my treatment?", ctx)
    assert "NCCN" not in reply
    assert "National Comprehensive Cancer Network" not in reply
