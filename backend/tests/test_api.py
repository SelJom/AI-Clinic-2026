from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from health_coach import config, storage
from health_coach.models import DailyFeatures, RiskAssessment, RiskLevel, RuleHit


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    storage.init_db()
    from health_coach.api import app

    return TestClient(app)


def _seed_two_days(patient_id="p1"):
    old_day = date(2026, 1, 1)
    new_day = date(2026, 1, 5)

    storage.save_daily_features(
        DailyFeatures(patient_id, old_day, resting_hr=70.0, sleep_hours=7.0, steps=6000)
    )
    storage.save_risk_assessment(
        RiskAssessment(patient_id=patient_id, day=old_day, level=RiskLevel.NORMAL, hits=[])
    )

    storage.save_daily_features(
        DailyFeatures(patient_id, new_day, resting_hr=130.0, sleep_hours=6.0, steps=4000)
    )
    storage.save_risk_assessment(
        RiskAssessment(
            patient_id=patient_id,
            day=new_day,
            level=RiskLevel.ESCALATE,
            hits=[
                RuleHit(
                    rule_id="tachycardia_severe",
                    description="Resting heart rate is markedly elevated versus the patient's own baseline.",
                    risk_level=RiskLevel.ESCALATE,
                )
            ],
        )
    )
    return old_day, new_day


def test_summary_matches_requested_day_not_latest_assessment(client):
    old_day, new_day = _seed_two_days()

    resp = client.get("/summary/p1", params={"day": old_day.isoformat()})
    assert resp.status_code == 200
    body = resp.json()

    # Regression test: this endpoint used to always return the *latest*
    # risk assessment (day=2026-01-05, escalate) even when an older day's
    # features were requested, so an old-day query would show today's
    # unrelated risk level and findings.
    assert body["day"] == old_day.isoformat()
    assert body["resting_hr"] == 70.0
    assert body["risk_level"] == "normal"
    assert body["hits"] == []


def test_summary_defaults_to_latest_day(client):
    old_day, new_day = _seed_two_days()

    resp = client.get("/summary/p1")
    assert resp.status_code == 200
    body = resp.json()

    assert body["day"] == new_day.isoformat()
    assert body["risk_level"] == "escalate"
    assert body["hits"] == ["Resting heart rate is markedly elevated versus the patient's own baseline."]


def test_summary_404_when_no_data(client):
    resp = client.get("/summary/nobody")
    assert resp.status_code == 404


def test_health_endpoint_reports_llm_backend(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    assert resp.json()["llm_backend"] in ("ollama", "template")


def test_cors_allows_loopback_origin_with_a_real_port(client):
    """Regression test for a real bug found by actually running the Flutter
    web build against this backend (not just unit-testing each side
    separately): CORS allow_origins listed "http://127.0.0.1" with no port,
    but real browsers always send the port in the Origin header (e.g.
    "http://127.0.0.1:5050" for `flutter run -d web-server`), so it never
    matched and every request was silently blocked - the app showed
    "Offline" even with the backend actually running and reachable."""
    resp = client.options(
        "/ingest",
        headers={
            "Origin": "http://127.0.0.1:5050",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert resp.status_code == 200
    assert resp.headers["access-control-allow-origin"] == "http://127.0.0.1:5050"


def test_cors_rejects_non_loopback_origin(client):
    resp = client.options(
        "/ingest",
        headers={
            "Origin": "http://evil.example.com",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert "access-control-allow-origin" not in resp.headers


def test_trend_returns_real_days_oldest_to_newest(client):
    old_day, new_day = _seed_two_days()

    resp = client.get("/trend/p1")
    assert resp.status_code == 200
    body = resp.json()

    assert body["patient_id"] == "p1"
    assert [d["day"] for d in body["days"]] == [old_day.isoformat(), new_day.isoformat()]
    assert body["days"][0]["resting_hr"] == 70.0
    assert body["days"][1]["resting_hr"] == 130.0


def test_trend_empty_for_unknown_patient(client):
    resp = client.get("/trend/nobody")
    assert resp.status_code == 200
    assert resp.json()["days"] == []


def test_trend_days_param_is_clamped(client):
    _seed_two_days()
    resp = client.get("/trend/p1", params={"days": 99999})
    assert resp.status_code == 200
    # Clamped to the max, not literally 99999 - just checking it didn't 500
    # and still returns the (small) real result set.
    assert len(resp.json()["days"]) == 2


def test_trend_weekly_period_aggregates(client):
    _seed_two_days()  # 2026-01-01 (ISO week 1) and 2026-01-05 (ISO week 2)
    resp = client.get("/trend/p1", params={"period": "weekly"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["period"] == "weekly"
    assert "periods" in body
    assert "days" not in body
    assert len(body["periods"]) == 2  # different ISO weeks - two separate buckets
    assert all(p["day_count"] == 1 for p in body["periods"])


def test_trend_rejects_invalid_period(client):
    resp = client.get("/trend/p1", params={"period": "yearly"})
    assert resp.status_code == 400


def test_summary_includes_calories(client):
    old_day, new_day = _seed_two_days()
    storage.save_daily_features(
        DailyFeatures(patient_id="p1", day=new_day, resting_hr=130.0, sleep_hours=6.0, steps=4000, calories=320.5)
    )
    resp = client.get("/summary/p1")
    assert resp.status_code == 200
    assert resp.json()["calories"] == 320.5


def test_activity_summary_returns_deterministic_label_and_ai_why(client):
    day = date(2026, 8, 30)
    storage.save_daily_features(
        DailyFeatures(patient_id="p1", day=day, resting_hr=68.0, sleep_hours=7.5, steps=11000, calories=450.0)
    )
    storage.save_risk_assessment(RiskAssessment(patient_id="p1", day=day, level=RiskLevel.NORMAL, hits=[]))

    resp = client.get("/activity-summary/p1")
    assert resp.status_code == 200
    body = resp.json()
    assert body["level"] == "Excellent"
    assert body["tier"] == "positive"
    assert isinstance(body["summary"], str) and len(body["summary"]) > 0


def test_activity_summary_404_when_no_data(client):
    resp = client.get("/activity-summary/nobody")
    assert resp.status_code == 404
