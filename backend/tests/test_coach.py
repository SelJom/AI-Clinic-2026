from datetime import date, timedelta

import pytest

from health_coach import config, storage
from health_coach.coach import CoachAgent, _format_trend
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
    )
    reply = OllamaBackend().generate("What is the least I slept this week, in hours?", ctx)
    assert "5.1" in reply
