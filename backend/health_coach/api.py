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
from .models import SignalType, WearableSample
from .pipeline import process_samples

app = FastAPI(title="Health Coach Local API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1", "http://localhost", "capacitor://localhost"],
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
    assessment = storage.load_latest_risk_assessment(patient_id)
    if not history:
        raise HTTPException(404, "no data for this patient/day yet")

    features = history[-1]
    return {
        "day": str(features.day),
        "resting_hr": features.resting_hr,
        "sleep_hours": features.sleep_hours,
        "steps": features.steps,
        "hr_zscore": features.hr_zscore,
        "sleep_zscore": features.sleep_zscore,
        "steps_zscore": features.steps_zscore,
        "risk_level": assessment.level.value if assessment else "unknown",
        "hits": [h.description for h in assessment.hits] if assessment else [],
    }


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
