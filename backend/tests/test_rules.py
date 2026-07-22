from datetime import date

from health_coach.models import DailyFeatures, RiskLevel
from health_coach.rules import evaluate


def test_no_hits_when_features_within_baseline():
    features = DailyFeatures(
        "p1", date(2026, 1, 1),
        resting_hr=70, hr_zscore=0.2,
        sleep_hours=7.5, sleep_zscore=0.1,
        steps=7000, steps_zscore=-0.3,
    )
    assessment = evaluate(features)
    assert assessment.level == RiskLevel.NORMAL
    assert assessment.hits == []


def test_severe_tachycardia_escalates():
    features = DailyFeatures("p1", date(2026, 1, 1), resting_hr=135, hr_zscore=4.0)
    assessment = evaluate(features)
    assert assessment.level == RiskLevel.ESCALATE
    assert assessment.escalate is True
    assert any(h.rule_id == "tachycardia_severe" for h in assessment.hits)


def test_moderate_tachycardia_is_elevated_not_escalated():
    features = DailyFeatures("p1", date(2026, 1, 1), resting_hr=105, hr_zscore=2.8)
    assessment = evaluate(features)
    assert assessment.level == RiskLevel.ELEVATED
    assert assessment.escalate is False


def test_sleep_collapse_flagged():
    features = DailyFeatures("p1", date(2026, 1, 1), sleep_hours=2.5)
    assessment = evaluate(features)
    assert assessment.level == RiskLevel.ELEVATED
    assert any(h.rule_id == "sleep_collapse" for h in assessment.hits)


def test_multiple_hits_take_the_highest_level():
    features = DailyFeatures(
        "p1", date(2026, 1, 1),
        resting_hr=135, hr_zscore=4.0,  # escalate
        sleep_hours=2.5,  # elevated
    )
    assessment = evaluate(features)
    assert assessment.level == RiskLevel.ESCALATE
    assert len(assessment.hits) == 2
