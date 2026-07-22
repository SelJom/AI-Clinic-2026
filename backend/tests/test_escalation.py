from datetime import date

from health_coach import storage
from health_coach.escalation import build_escalation_summary
from health_coach.models import DailyFeatures, RiskAssessment, RiskLevel, RuleHit


def _seed_history(db_path, patient_id="p1"):
    for i in range(5):
        storage.save_daily_features(
            DailyFeatures(
                patient_id, date(2026, 1, i + 1),
                resting_hr=70.0, sleep_hours=7.5, steps=7000,
                hr_baseline=70.0, hr_zscore=0.1,
                sleep_baseline=7.5, sleep_zscore=0.0,
                steps_baseline=7000, steps_zscore=0.0,
            ),
            db_path=db_path,
        )

    today = DailyFeatures(
        patient_id, date(2026, 1, 6),
        resting_hr=135.0, sleep_hours=7.4, steps=7100,
        hr_baseline=70.0, hr_zscore=4.2,
        sleep_baseline=7.5, sleep_zscore=-0.1,
        steps_baseline=7000, steps_zscore=0.1,
    )
    storage.save_daily_features(today, db_path=db_path)

    assessment = RiskAssessment(
        patient_id=patient_id,
        day=date(2026, 1, 6),
        level=RiskLevel.ESCALATE,
        hits=[
            RuleHit(
                rule_id="tachycardia_severe",
                description="Resting heart rate is markedly elevated versus the patient's own baseline.",
                risk_level=RiskLevel.ESCALATE,
                guideline_query="cardiac monitoring symptoms treatment toxicity",
            )
        ],
    )
    storage.save_risk_assessment(assessment, db_path=db_path)
    return today, assessment


def test_build_escalation_summary_returns_none_when_no_data(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    assert build_escalation_summary("nobody", db_path=db_path) is None


def test_build_escalation_summary_matches_stored_assessment(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    today, assessment = _seed_history(db_path)

    summary = build_escalation_summary("p1", db_path=db_path)

    assert summary is not None
    assert summary.patient_id == "p1"
    assert summary.day == date(2026, 1, 6)
    assert summary.risk_level == "escalate"
    assert summary.escalate is True
    assert summary.features.resting_hr == 135.0
    assert len(summary.recent_trend) == 5
    assert summary.recent_trend[0].day == date(2026, 1, 1)
    assert any(rec.escalate for rec in summary.recommendations)


def test_escalation_summary_text_includes_key_facts(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    _seed_history(db_path)

    summary = build_escalation_summary("p1", db_path=db_path)
    text = summary.to_text()

    assert "p1" in text
    assert "2026-01-06" in text
    assert "ESCALATE" in text
    assert "135" in text


def test_escalation_summary_for_specific_day(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    _seed_history(db_path)

    assert build_escalation_summary("p1", day=date(2026, 1, 6), db_path=db_path) is not None
    assert build_escalation_summary("p1", day=date(2099, 1, 1), db_path=db_path) is None
