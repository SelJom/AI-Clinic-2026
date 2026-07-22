from __future__ import annotations

from datetime import datetime, timezone

from . import storage
from .guidelines import GuidelineStore, get_default_store
from .llm_backends import ConversationBackend, CoachContext, get_default_backend
from .models import ChatTurn, Recommendation, RiskAssessment


class CoachAgent:
    def __init__(
        self,
        backend: ConversationBackend | None = None,
        guideline_store: GuidelineStore | None = None,
    ):
        self.backend = backend or get_default_backend()
        self.guideline_store = guideline_store or get_default_store()

    def handle_message(
        self,
        patient_id: str,
        message: str,
        latest_assessment: RiskAssessment | None = None,
        latest_recommendations: list[Recommendation] | None = None,
    ) -> str:
        latest_assessment = latest_assessment or storage.load_latest_risk_assessment(patient_id)
        recommendations = latest_recommendations or []

        recommendation_summaries = [r.body for r in recommendations]
        guideline_snippets = [
            f"[{c.evidence_level or '?'},{c.recommendation_grade or '?'}] {c.text[:220]}"
            for r in recommendations
            for c in r.citations
        ]
        if not guideline_snippets:
            retrieved = self.guideline_store.retrieve(message, k=2)
            guideline_snippets = [
                f"[{s.evidence_level or '?'},{s.recommendation_grade or '?'}] {s.text[:220]}"
                for s in retrieved
            ]

        recent_chat = [(t.role, t.text) for t in storage.load_chat_history(patient_id, limit=6)]

        context = CoachContext(
            patient_id=patient_id,
            risk_level=latest_assessment.level.value if latest_assessment else "unknown",
            recommendation_summaries=recommendation_summaries,
            guideline_snippets=guideline_snippets,
            escalate=bool(latest_assessment and latest_assessment.escalate),
            recent_chat=recent_chat,
        )

        reply = self.backend.generate(message, context)

        now = datetime.now(timezone.utc)
        storage.save_chat_turn(ChatTurn(patient_id, "user", message, now))
        storage.save_chat_turn(ChatTurn(patient_id, "coach", reply, now))
        return reply

    def explain_last_recommendation(self, patient_id: str) -> str:
        assessment = storage.load_latest_risk_assessment(patient_id)
        if assessment is None:
            return "I don't have any assessment for you yet - sync some data first."
        if not assessment.hits:
            return "Nothing was flagged: your recent heart rate, sleep, and activity are all close to your own baseline."

        lines = [f"On {assessment.day}, I flagged the following against your personal baseline:"]
        for hit in assessment.hits:
            lines.append(f"• {hit.description} (rule: {hit.rule_id}, level: {hit.risk_level.value})")
        return "\n".join(lines)
