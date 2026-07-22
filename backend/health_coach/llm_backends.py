from __future__ import annotations

import json
import urllib.error
import urllib.request
from abc import ABC, abstractmethod
from dataclasses import dataclass

from . import config


@dataclass
class CoachContext:
    patient_id: str
    risk_level: str
    recommendation_summaries: list[str]
    guideline_snippets: list[str]
    escalate: bool
    recent_chat: list[tuple[str, str]]  # (role, text)


SYSTEM_PROMPT = (
    "You are a supportive, empathetic digital health coach for a cancer patient. "
    "You are NOT a doctor and must never present yourself as one. "
    "Ground every piece of advice in the structured data and guideline excerpts "
    "you are given below; do not invent clinical facts. "
    "Keep replies short (3-5 sentences), warm, and non-alarmist. "
    "If escalate is true, clearly and calmly tell the patient to contact their "
    "care team, and explain briefly why."
)


class ConversationBackend(ABC):
    name: str

    @abstractmethod
    def generate(self, user_message: str, context: CoachContext) -> str: ...


class TemplateBackend(ConversationBackend):
    """Deterministic, zero-dependency fallback. Always available offline."""

    name = "template"

    def generate(self, user_message: str, context: CoachContext) -> str:
        lines = []

        if context.escalate:
            lines.append(
                "⚠️ Based on today's data, I'd like you to reach out to your care team "
                "when you can - this isn't an emergency alarm, just a pattern worth them knowing about."
            )

        if context.recommendation_summaries:
            lines.append("Here's what I'm seeing:")
            for s in context.recommendation_summaries:
                lines.append(f"• {s}")
        else:
            lines.append(
                "Your recent numbers look consistent with your own normal - nothing stands out today."
            )

        if context.guideline_snippets:
            lines.append("")
            lines.append("Relevant guideline context:")
            for snip in context.guideline_snippets[:2]:
                lines.append(f"- {snip}")

        message = user_message.lower()
        if any(k in message for k in ("why", "pourquoi")):
            lines.append("")
            lines.append(
                "I based this on your heart rate, sleep, and activity compared to your own recent baseline, "
                "cross-checked against the guideline excerpts above."
            )

        return "\n".join(lines)


class OllamaBackend(ConversationBackend):
    """Talks to a local Ollama daemon on loopback only. Never used unless it
    is already running on this machine - no network calls otherwise."""

    name = "ollama"

    def __init__(self, url: str = config.OLLAMA_URL, model: str = config.OLLAMA_MODEL):
        self.url = url
        self.model = model

    def generate(self, user_message: str, context: CoachContext) -> str:
        prompt = self._build_prompt(user_message, context)
        payload = json.dumps(
            {"model": self.model, "prompt": prompt, "stream": False}
        ).encode("utf-8")
        req = urllib.request.Request(
            f"{self.url}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        return body.get("response", "").strip()

    def _build_prompt(self, user_message: str, context: CoachContext) -> str:
        history = "\n".join(f"{role}: {text}" for role, text in context.recent_chat[-6:])
        recs = "\n".join(f"- {s}" for s in context.recommendation_summaries) or "- none today"
        cites = "\n".join(f"- {s}" for s in context.guideline_snippets) or "- none retrieved"
        return (
            f"{SYSTEM_PROMPT}\n\n"
            f"Risk level: {context.risk_level}\n"
            f"Escalate: {context.escalate}\n"
            f"Today's findings:\n{recs}\n\n"
            f"Guideline excerpts:\n{cites}\n\n"
            f"Recent conversation:\n{history}\n\n"
            f"Patient just said: {user_message}\n"
            f"Coach reply:"
        )


def ollama_is_reachable(url: str = config.OLLAMA_URL, timeout: float = config.OLLAMA_TIMEOUT_S) -> bool:
    try:
        req = urllib.request.Request(f"{url}/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError, TimeoutError):
        return False


def get_default_backend() -> ConversationBackend:
    if ollama_is_reachable():
        return OllamaBackend()
    return TemplateBackend()
