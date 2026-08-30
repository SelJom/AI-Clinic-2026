from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from . import config


@dataclass
class CoachContext:
    patient_id: str
    risk_level: str
    recommendation_summaries: list[str]
    guideline_snippets: list[str]
    escalate: bool
    recent_chat: list[tuple[str, str]]  # (role, text)
    recent_trend: list[str] = field(default_factory=list)  # pre-formatted "day: RHR x, sleep yh, steps z" lines
    trend_stats: list[str] = field(default_factory=list)  # precomputed avg/lowest/highest per metric


SYSTEM_PROMPT = (
    "You are a supportive, empathetic digital health coach for a cancer patient. "
    "You are NOT a doctor and must never present yourself as one. "
    "Ground every piece of advice in the structured data, recent trend, and "
    "guideline excerpts you are given below; do not invent clinical facts. "
    "The 'Recent daily trend' section below lists this patient's real "
    "resting HR, sleep hours, and steps for each individual day, oldest to "
    "newest, and 'Precomputed trend statistics' gives you the average, "
    "lowest, and highest value of each metric already calculated over that "
    "same period. Both are the ONLY source of truth for numbers - never "
    "state a number that isn't taken directly from one of them. For a "
    "question about a single day (e.g. what happened on a specific date), "
    "look it up in the daily trend. For a question about an average, total, "
    "lowest, highest, or typical value over the period, ALWAYS copy the "
    "matching figure from 'Precomputed trend statistics' instead of trying "
    "to calculate it yourself from the daily list - you are not reliable at "
    "arithmetic over many numbers, so never compute an average by hand. "
    "Only refuse to answer, plainly saying you don't have that figure, when "
    "the answer truly requires information not listed anywhere below (e.g. "
    "days outside this window, or a signal that was never recorded). Some "
    "lines in the daily trend end with a '[FLAGGED ...]' tag - that means "
    "the rule engine already determined that specific day was NOT normal. "
    "If asked about a flagged day, you MUST reflect that in your answer "
    "(e.g. note the concern and, if it says ESCALATE, recommend contacting "
    "the care team) - never call a flagged day normal, fine, or nothing to "
    "worry about, even if the raw number alone might look unremarkable to "
    "you. Keep replies short (3-5 sentences), warm, and non-alarmist. "
    "If escalate is true, clearly and calmly tell the patient to contact their "
    "care team, and explain briefly why."
)


# Numbers adjacent to one of these units are treated as claims about the
# patient's own resting HR / sleep / step count specifically - the category
# of number that was actually observed to get fabricated. Bidirectional:
# observed live, "steps were 8500" (unit-before-number) slipped through
# a number-then-unit-only pattern that only caught "8500 steps".
_UNIT_PATTERNS: dict[str, re.Pattern[str]] = {
    "bpm": re.compile(r"\d+(?:\.\d+)?\s*bpm|\bbpm\D{0,15}?\d+(?:\.\d+)?", re.IGNORECASE),
    "h": re.compile(r"\d+(?:\.\d+)?\s*h(?:ours?)?\b|\bh(?:ours?)?\D{0,15}?\d+(?:\.\d+)?", re.IGNORECASE),
    "steps": re.compile(r"\d+(?:,\d{3})*\s*steps?\b|\bsteps?\D{0,15}?\d+(?:,\d{3})*", re.IGNORECASE),
}
_NUMBER_RE = re.compile(r"\d+(?:,\d{3})*(?:\.\d+)?")
_TOLERANCE = {"bpm": 0.6, "h": 0.06, "steps": 0.6}


def _numbers_in(text: str, unit: str) -> set[float]:
    values = set()
    for match in _UNIT_PATTERNS[unit].finditer(text):
        num_match = _NUMBER_RE.search(match.group(0))
        if num_match:
            values.add(float(num_match.group(0).replace(",", "")))
    return values


def _grounded_values(context: CoachContext) -> dict[str, set[float]]:
    """Every number that actually appears anywhere in the real data/citations
    given to the model - trend, precomputed stats, today's findings, and
    retrieved guideline text. Not just recent_trend, since a number the model
    is relaying from a real guideline citation is just as grounded as one
    from the patient's own daily numbers."""
    source = "\n".join(
        context.recent_trend + context.trend_stats
        + context.recommendation_summaries + context.guideline_snippets
    )
    return {unit: _numbers_in(source, unit) for unit in _UNIT_PATTERNS}


def ground_reply(reply: str, context: CoachContext) -> str:
    """Unconditional post-generation safety net, independent of how the
    question was phrased: any resting-HR/sleep/steps figure the model states
    that doesn't actually appear anywhere in the real data it was given gets
    replaced. SYSTEM_PROMPT's instructions are the first line of defense and
    cover most phrasings, but they're a bet on the model following
    instructions; this is a hard check on the output that doesn't depend on
    that bet paying off - the actual fix for "we can't prompt-engineer our
    way around every possible question."

    Known tradeoff: this can also strip legitimate generic advice that
    happens to share a unit with patient data (e.g. "aim for 7-9 hours of
    sleep" isn't a claim about this patient, but reads the same to the
    regex). Given the demonstrated fabrication risk, catching every
    patient-data hallucination is prioritized over preserving generic
    numeric advice - it degrades to a vaguer phrasing, not a wrong claim.
    """
    grounded = _grounded_values(context)

    for unit, pattern in _UNIT_PATTERNS.items():

        def repl(match: re.Match[str], unit: str = unit) -> str:
            num_match = _NUMBER_RE.search(match.group(0))
            if not num_match:
                return match.group(0)
            value = float(num_match.group(0).replace(",", ""))
            if any(abs(value - g) <= _TOLERANCE[unit] for g in grounded[unit]):
                return match.group(0)
            return "a specific figure I don't have handy"

        reply = pattern.sub(repl, reply)

    return reply


# Matches the "Full Organization Name (ACRONYM)" shape specifically - a
# distinctive pattern for the model inventing an authoritative-sounding
# citation, e.g. "National Comprehensive Cancer Network (NCCN)". Our real
# guideline_snippets never self-cite this way, so this pattern almost never
# fires on legitimate text.
_CITATION_RE = re.compile(r"\b([A-Z][A-Za-z&']*(?:\s+[A-Z][A-Za-z&']*){1,6})\s*\(([A-Z]{2,8})\)")

# Observed live: even after the pattern above was fixed, the model pivoted to
# citing a bare acronym with no parenthetical full name at all (e.g. "the FDA
# has not approved ibuprofen..."). Same fabrication, different shape - a
# fixed vocabulary of known health-authority acronyms, checked as standalone
# words, closes that specific gap without the false-positive risk of matching
# arbitrary capitalized text.
_KNOWN_AUTHORITY_ACRONYMS = (
    "FDA", "NCCN", "ASCO", "ESMO", "WHO", "NCI", "CDC", "AHA", "ACS", "EMA", "NHS",
)
_BARE_AUTHORITY_RE = re.compile(
    r"\b(" + "|".join(_KNOWN_AUTHORITY_ACRONYMS) + r")\b"
)


def ground_citations(reply: str, context: CoachContext) -> str:
    """Strips fabricated named-source attributions - observed live: asked
    about a medication interaction, the model attributed its answer first to
    the "National Comprehensive Cancer Network (NCCN)", then (after that
    pattern was caught) to "the FDA" with no parenthetical name at all -
    neither was ever in guideline_snippets; both were invented from general
    training knowledge and presented as if retrieved.

    Deliberately narrow on both patterns: general "according to X" phrasing
    isn't checked, because that also matches legitimate self-references this
    code generates itself (e.g. "according to the Precomputed trend
    statistics") that must not be stripped. The bare-acronym check is
    limited to a fixed vocabulary of known health authorities rather than
    any capitalized word, for the same false-positive reason. An
    organization named some other way entirely (no acronym, not on the
    list) still isn't covered - a known gap, not a claim of full coverage.
    """
    source = " ".join(context.guideline_snippets).lower()

    def repl_named(match: re.Match[str]) -> str:
        full_name, acronym = match.group(1), match.group(2)
        if full_name.lower() in source or acronym.lower() in source:
            return match.group(0)
        return "a general clinical source"

    reply = _CITATION_RE.sub(repl_named, reply)

    def repl_bare(match: re.Match[str]) -> str:
        acronym = match.group(1)
        if acronym.lower() in source:
            return match.group(0)
        return "a general clinical source"

    return _BARE_AUTHORITY_RE.sub(repl_bare, reply)


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
        reply = body.get("response", "").strip()
        reply = ground_reply(reply, context)
        reply = ground_citations(reply, context)
        return reply

    def _build_prompt(self, user_message: str, context: CoachContext) -> str:
        history = "\n".join(f"{role}: {text}" for role, text in context.recent_chat[-6:])
        recs = "\n".join(f"- {s}" for s in context.recommendation_summaries) or "- none today"
        cites = "\n".join(f"- {s}" for s in context.guideline_snippets) or "- none retrieved"
        trend = "\n".join(f"- {s}" for s in context.recent_trend) or "- no recent data recorded"
        stats = "\n".join(f"- {s}" for s in context.trend_stats) or (
            "- none computed for this period (the daily trend below may still have real "
            "data for single-day lookups even when this section is empty)"
        )
        return (
            f"{SYSTEM_PROMPT}\n\n"
            f"Risk level: {context.risk_level}\n"
            f"Escalate: {context.escalate}\n"
            f"Today's findings:\n{recs}\n\n"
            f"Precomputed trend statistics (use these directly for any average/total/lowest/highest "
            f"question - do not recompute):\n{stats}\n\n"
            f"Recent daily trend (oldest to newest, for single-day lookups):\n{trend}\n\n"
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
