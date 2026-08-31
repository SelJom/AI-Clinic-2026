from datetime import date

from health_coach.activity import classify_activity_level
from health_coach.models import DailyFeatures, RiskAssessment, RiskLevel, RuleHit


def _features(steps):
    return DailyFeatures("p1", date(2026, 1, 1), steps=steps)


def test_classify_ranks_by_step_tiers_when_no_assessment():
    assert classify_activity_level(_features(10500), None).label == "Excellent"
    assert classify_activity_level(_features(8000), None).label == "Great"
    assert classify_activity_level(_features(5500), None).label == "Good"
    assert classify_activity_level(_features(3000), None).label == "Fair"
    assert classify_activity_level(_features(500), None).label == "Low"


def test_classify_ranks_by_step_tiers_when_assessment_is_normal():
    assessment = RiskAssessment("p1", date(2026, 1, 1), RiskLevel.NORMAL)
    assert classify_activity_level(_features(10500), assessment).label == "Excellent"


def test_classify_escalate_always_wins_even_with_high_steps():
    """A real escalate-level finding (e.g. a heart rate spike) must never be
    overridden by a merely-high step count that day."""
    assessment = RiskAssessment(
        "p1", date(2026, 1, 1), RiskLevel.ESCALATE,
        hits=[RuleHit("tachycardia_severe", "HR spike", RiskLevel.ESCALATE)],
    )
    level = classify_activity_level(_features(15000), assessment)
    assert level.label == "Rest"
    assert level.tier == "concern"


def test_classify_elevated_overrides_high_steps():
    assessment = RiskAssessment("p1", date(2026, 1, 1), RiskLevel.ELEVATED)
    level = classify_activity_level(_features(12000), assessment)
    assert level.label == "Take It Easy"
    assert level.tier == "caution"


def test_classify_watch_overrides_high_steps():
    assessment = RiskAssessment("p1", date(2026, 1, 1), RiskLevel.WATCH)
    level = classify_activity_level(_features(12000), assessment)
    assert level.label == "Fair"


def test_classify_handles_missing_steps():
    assert classify_activity_level(DailyFeatures("p1", date(2026, 1, 1)), None).label == "Low"
