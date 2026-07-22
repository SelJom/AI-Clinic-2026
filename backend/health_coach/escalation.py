"""Builds a clinician-facing escalation summary - the piece that was
entirely missing from "Risk Monitoring & Escalation": until now, an
escalation only produced a chat message telling the *patient* to contact
their care team. There was no artifact a patient could actually bring to,
show, or send a clinician.

This stays consistent with the rest of the project's local-first design: it
does not send anything anywhere. It assembles what's already been computed
(stored daily features, the stored risk assessment, freshly recomputed
guideline-grounded recommendations) into one clinician-readable report the
patient can view, copy, or export from the app themselves.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta

from . import storage
from .guidelines import GuidelineStore
from .models import DailyFeatures, Recommendation, RiskAssessment
from .rules import RULES, Rule, build_recommendations


def _fmt(value: float | None, digits: int = 1) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def _fmt_z(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:+.1f}"


@dataclass
class EscalationSummary:
    patient_id: str
    day: date
    risk_level: str
    escalate: bool
    features: DailyFeatures
    recommendations: list[Recommendation]
    recent_trend: list[DailyFeatures] = field(default_factory=list)

    def to_text(self) -> str:
        lines = [
            "ESCALATION SUMMARY - for review with your care team",
            "(generated locally; not a diagnosis)",
            "",
            f"Patient: {self.patient_id}",
            f"Date: {self.day.isoformat()}",
            f"Risk level: {self.risk_level.upper()}",
            "",
            "Today's measurements vs. this patient's own recent baseline:",
            f"  Resting heart rate: {_fmt(self.features.resting_hr)} bpm "
            f"(baseline {_fmt(self.features.hr_baseline)}, z-score {_fmt_z(self.features.hr_zscore)})",
            f"  Sleep: {_fmt(self.features.sleep_hours)}h "
            f"(baseline {_fmt(self.features.sleep_baseline)}, z-score {_fmt_z(self.features.sleep_zscore)})",
            f"  Steps: {_fmt(self.features.steps, 0)} "
            f"(baseline {_fmt(self.features.steps_baseline, 0)}, z-score {_fmt_z(self.features.steps_zscore)})",
        ]

        if self.recommendations:
            lines.append("")
            lines.append("Flagged findings:")
            for rec in self.recommendations:
                tag = " [ESCALATE]" if rec.escalate else ""
                lines.append(f"  - {rec.title}{tag}")
                for cite in rec.citations:
                    level = cite.evidence_level or "?"
                    lines.append(f"      guideline context [{level}]: {cite.text[:200]}")

        if self.recent_trend:
            lines.append("")
            lines.append(f"Recent trend (last {len(self.recent_trend)} days before today):")
            for f in self.recent_trend:
                lines.append(
                    f"  {f.day.isoformat()}: RHR {_fmt(f.resting_hr, 0)}, "
                    f"Sleep {_fmt(f.sleep_hours)}h, Steps {_fmt(f.steps, 0)}"
                )

        lines.append("")
        lines.append(
            "This summary reflects deterministic rules and guideline retrieval "
            "run on-device; it does not replace clinical judgment."
        )
        return "\n".join(lines)

    def to_dict(self) -> dict:
        return {
            "patient_id": self.patient_id,
            "day": self.day.isoformat(),
            "risk_level": self.risk_level,
            "escalate": self.escalate,
            "features": {
                "resting_hr": self.features.resting_hr,
                "hr_baseline": self.features.hr_baseline,
                "hr_zscore": self.features.hr_zscore,
                "sleep_hours": self.features.sleep_hours,
                "sleep_baseline": self.features.sleep_baseline,
                "sleep_zscore": self.features.sleep_zscore,
                "steps": self.features.steps,
                "steps_baseline": self.features.steps_baseline,
                "steps_zscore": self.features.steps_zscore,
            },
            "findings": [
                {
                    "title": rec.title,
                    "body": rec.body,
                    "escalate": rec.escalate,
                    "citations": [
                        {
                            "guideline_id": c.guideline_id,
                            "evidence_level": c.evidence_level,
                            "text": c.text,
                        }
                        for c in rec.citations
                    ],
                }
                for rec in self.recommendations
            ],
            "recent_trend": [
                {
                    "day": f.day.isoformat(),
                    "resting_hr": f.resting_hr,
                    "sleep_hours": f.sleep_hours,
                    "steps": f.steps,
                }
                for f in self.recent_trend
            ],
            "text": self.to_text(),
        }


def build_escalation_summary(
    patient_id: str,
    day: date | None = None,
    trend_days: int = 14,
    rules: list[Rule] = RULES,
    guideline_store: GuidelineStore | None = None,
    db_path=None,
) -> EscalationSummary | None:
    """Builds a summary for `day` (default: the patient's most recently
    recorded day). Returns None if there's no stored assessment yet - the
    caller should treat that as "sync some data first", same as /summary."""
    assessment = _load_assessment_for_day(patient_id, day, db_path)
    if assessment is None:
        return None

    target_day = assessment.day
    day_features = storage.load_recent_daily_features(
        patient_id, before=target_day + timedelta(days=1), limit_days=1, db_path=db_path
    )
    if not day_features:
        return None
    features = day_features[-1]

    recommendations = build_recommendations(features, assessment, rules, guideline_store)
    recent_trend = storage.load_recent_daily_features(
        patient_id, before=target_day, limit_days=trend_days, db_path=db_path
    )

    return EscalationSummary(
        patient_id=patient_id,
        day=target_day,
        risk_level=assessment.level.value,
        escalate=assessment.escalate,
        features=features,
        recommendations=recommendations,
        recent_trend=recent_trend,
    )


def _load_assessment_for_day(patient_id: str, day: date | None, db_path) -> RiskAssessment | None:
    if day is None:
        return storage.load_latest_risk_assessment(patient_id, db_path=db_path)
    return storage.load_risk_assessment_for_day(patient_id, day, db_path=db_path)
