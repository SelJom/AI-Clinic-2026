from datetime import date, datetime, timezone

from health_coach import storage
from health_coach.models import DailyFeatures, RiskAssessment, RiskLevel, SignalType, WearableSample


def _seed(db_path, patient_id="p1", other_id="p2"):
    storage.save_samples(
        [
            WearableSample(patient_id, SignalType.STEPS, 5000, datetime(2026, 1, 1, tzinfo=timezone.utc)),
            WearableSample(other_id, SignalType.STEPS, 6000, datetime(2026, 1, 1, tzinfo=timezone.utc)),
        ],
        db_path=db_path,
    )
    storage.save_daily_features(
        DailyFeatures(patient_id, date(2026, 1, 1), resting_hr=70.0), db_path=db_path
    )
    storage.save_daily_features(
        DailyFeatures(other_id, date(2026, 1, 1), resting_hr=72.0), db_path=db_path
    )
    storage.save_risk_assessment(
        RiskAssessment(patient_id, date(2026, 1, 1), RiskLevel.NORMAL), db_path=db_path
    )
    storage.save_risk_assessment(
        RiskAssessment(other_id, date(2026, 1, 1), RiskLevel.NORMAL), db_path=db_path
    )


def test_export_patient_data_returns_only_that_patient(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    _seed(db_path)

    export = storage.export_patient_data("p1", db_path=db_path)

    assert export["patient_id"] == "p1"
    assert len(export["samples"]) == 1
    assert export["samples"][0]["patient_id"] == "p1"
    assert len(export["daily_features"]) == 1
    assert len(export["risk_assessments"]) == 1


def test_delete_patient_data_only_removes_that_patient(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    _seed(db_path)

    counts = storage.delete_patient_data("p1", db_path=db_path)

    assert counts["samples"] == 1
    assert counts["daily_features"] == 1
    assert counts["risk_assessments"] == 1

    # p1 is gone...
    assert storage.export_patient_data("p1", db_path=db_path)["samples"] == []
    # ...but p2's data survives untouched.
    other = storage.export_patient_data("p2", db_path=db_path)
    assert len(other["samples"]) == 1
    assert len(other["daily_features"]) == 1


def test_delete_patient_data_is_idempotent(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    _seed(db_path)

    storage.delete_patient_data("p1", db_path=db_path)
    counts = storage.delete_patient_data("p1", db_path=db_path)

    assert all(n == 0 for n in counts.values())


def test_load_recent_risk_assessments_returns_oldest_to_newest_within_window(tmp_path):
    db_path = tmp_path / "test.db"
    storage.init_db(db_path=db_path)
    storage.save_risk_assessment(
        RiskAssessment("p1", date(2026, 1, 1), RiskLevel.NORMAL), db_path=db_path
    )
    storage.save_risk_assessment(
        RiskAssessment("p1", date(2026, 1, 2), RiskLevel.ESCALATE), db_path=db_path
    )
    storage.save_risk_assessment(
        RiskAssessment("p1", date(2026, 1, 3), RiskLevel.NORMAL), db_path=db_path
    )

    result = storage.load_recent_risk_assessments(
        "p1", before=date(2026, 1, 4), limit_days=14, db_path=db_path
    )

    assert [a.day for a in result] == [date(2026, 1, 1), date(2026, 1, 2), date(2026, 1, 3)]
    assert result[1].level == RiskLevel.ESCALATE
