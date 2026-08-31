"""Local-only HTTP bridge for the Flutter app. Binds to 127.0.0.1 by default
(see cli.py `serve`) and is meant to be reached via `adb reverse` / the iOS
simulator loopback / same-device Flutter desktop build - never exposed on a
public interface. This replaces the hardcoded demo values currently in
lib/services/health_service.dart and the canned replies in
lib/screens/ai_chat_screen.dart once the Dart side is wired to call it.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from . import storage
from .coach import CoachAgent
from .escalation import build_escalation_summary
from .features import aggregate_period
from .models import SignalType, WearableSample
from .pipeline import process_samples

app = FastAPI(title="Health Coach Local API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["capacitor://localhost"],
    # Real browsers always include the port in the Origin header (e.g.
    # "http://127.0.0.1:5050" for `flutter run -d chrome`/web-server), so a
    # port-less entry in allow_origins never matches and CORS silently blocks
    # every request - confirmed live: the Flutter web build showed "Offline"
    # even with the backend actually running, because the browser's preflight
    # request was rejected before the app ever got a real error to report.
    # A regex matching loopback on any port keeps the same "local only"
    # intent while actually working for a real dev-server port.
    allow_origin_regex=r"^https?://(127\.0\.0\.1|localhost)(:\d+)?$",
    allow_methods=["*"],
    allow_headers=["*"],
)

_agent = CoachAgent()


class SampleIn(BaseModel):
    signal: SignalType
    value: float
    timestamp: datetime
    source: str = "watch"


class IngestRequest(BaseModel):
    patient_id: str
    samples: list[SampleIn]


class ChatRequest(BaseModel):
    patient_id: str
    message: str


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "llm_backend": _agent.backend.name}


@app.post("/ingest")
def ingest(req: IngestRequest) -> dict:
    samples = [
        WearableSample(req.patient_id, s.signal, s.value, s.timestamp, s.source) for s in req.samples
    ]
    if not samples:
        raise HTTPException(400, "no samples provided")
    results = process_samples(req.patient_id, samples)
    return {"days_processed": len(results), "latest_risk": results[-1].assessment.level.value}


@app.get("/summary/{patient_id}")
def summary(patient_id: str, day: date | None = None) -> dict:
    target_day = day or date.today()
    history = storage.load_recent_daily_features(patient_id, before=target_day + timedelta(days=1), limit_days=1)
    if not history:
        raise HTTPException(404, "no data for this patient/day yet")

    features = history[-1]
    assessment = storage.load_risk_assessment_for_day(patient_id, features.day)
    return {
        "day": str(features.day),
        "resting_hr": features.resting_hr,
        "sleep_hours": features.sleep_hours,
        "steps": features.steps,
        "calories": features.calories,
        "hr_zscore": features.hr_zscore,
        "sleep_zscore": features.sleep_zscore,
        "steps_zscore": features.steps_zscore,
        "calories_zscore": features.calories_zscore,
        "risk_level": assessment.level.value if assessment else "unknown",
        "hits": [h.description for h in assessment.hits] if assessment else [],
    }


@app.get("/trend/{patient_id}")
def trend(patient_id: str, days: int = 30, period: str = "daily") -> dict:
    """Multi-day history for charting - the app only ever surfaced this data
    inside chat answers before (see coach.py's recent_trend/trend_stats),
    never visually. Returns real stored rows only, oldest to newest; no
    padding to `days` with placeholder entries for days that don't exist.

    `period`: "daily" (default, unchanged shape), "weekly", or "monthly" -
    see features.aggregate_period() for how days are summed vs. averaged
    and what day_count means."""
    if period not in ("daily", "weekly", "monthly"):
        raise HTTPException(400, "period must be daily, weekly, or monthly")
    days = max(1, min(days, 400))
    history = storage.load_recent_daily_features(
        patient_id, before=date.today() + timedelta(days=1), limit_days=days
    )

    if period == "daily":
        return {
            "patient_id": patient_id,
            "period": period,
            "days": [
                {
                    "day": str(f.day),
                    "resting_hr": f.resting_hr,
                    "sleep_hours": f.sleep_hours,
                    "steps": f.steps,
                    "calories": f.calories,
                    "hr_baseline": f.hr_baseline,
                    "sleep_baseline": f.sleep_baseline,
                    "steps_baseline": f.steps_baseline,
                    "calories_baseline": f.calories_baseline,
                }
                for f in history
            ],
        }

    return {"patient_id": patient_id, "period": period, "periods": aggregate_period(history, period)}


@app.get("/activity-summary/{patient_id}")
def activity_summary(patient_id: str) -> dict:
    """Today's activity level - a deterministic label (see activity.py)
    plus an AI-generated, grounded explanation of why. Recomputed fresh on
    every call (nothing cached), so the app can safely re-request this
    whenever real data changes meaningfully during the day."""
    result = _agent.build_activity_summary(patient_id)
    if result is None:
        raise HTTPException(404, "no data for this patient yet")
    return result


@app.post("/chat")
def chat(req: ChatRequest) -> dict:
    reply = _agent.handle_message(req.patient_id, req.message)
    return {"reply": reply}


@app.get("/chat/{patient_id}/explain")
def explain(patient_id: str) -> dict:
    return {"explanation": _agent.explain_last_recommendation(patient_id)}


@app.get("/escalation/{patient_id}")
def escalation(patient_id: str, day: date | None = None) -> dict:
    """Clinician-facing summary for a risk assessment - structured fields
    plus a ready-to-share `text` block. This is the artifact a patient can
    actually show or send their care team, not just a chat message telling
    them to."""
    summary = build_escalation_summary(patient_id, day=day)
    if summary is None:
        raise HTTPException(404, "no risk assessment for this patient/day yet")
    return summary.to_dict()


@app.get("/patient/{patient_id}/export")
def export_patient(patient_id: str) -> dict:
    """Right-to-access/data-portability: every row stored locally for this
    patient, as plain JSON. Nothing is filtered or summarized."""
    return storage.export_patient_data(patient_id)


@app.delete("/patient/{patient_id}")
def delete_patient(patient_id: str) -> dict:
    """Right-to-erasure: deletes every row for this patient across all local
    tables. Irreversible - there is no soft-delete or recovery, matching the
    fact that nothing here is backed up anywhere off-device."""
    counts = storage.delete_patient_data(patient_id)
    return {"deleted": counts}
