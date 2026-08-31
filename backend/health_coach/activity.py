"""Deterministic activity-level classification, shown as the new hero card
on the Summary screen. The *label* (Excellent/Great/.../Rest) is never
AI-decided - it's a plain rule lookup, same "sensor model first, LLM last"
principle as rules.py. Only the natural-language *why* behind the label
(see coach.py's build_activity_summary) is ever asked of the model, and
that explanation goes through the same ground_reply/ground_citations safety
net as every other chat reply.
"""
from __future__ import annotations

from dataclasses import dataclass

from .models import DailyFeatures, RiskAssessment, RiskLevel


@dataclass(frozen=True)
class ActivityLevel:
    label: str  # shown on the card
    tier: str  # "positive" | "neutral" | "caution" | "concern" - drives UI color


# Bad-side tiers come from the same rule engine every other risk-facing
# feature in this app uses - a day the rule engine already flagged is never
# independently re-graded as "Excellent" just because steps were high.
_RISK_TIERS = {
    RiskLevel.ESCALATE: ActivityLevel("Rest", "concern"),
    RiskLevel.ELEVATED: ActivityLevel("Take It Easy", "caution"),
    RiskLevel.WATCH: ActivityLevel("Fair", "caution"),
}

# Good-side tiers are step-count bands - the same thresholds the Flutter
# app used to compute in isolation (today_screen.dart's old
# _getActivityLevel()), moved server-side so the app and backend agree on
# one definition instead of two independently-maintained ones.
_STEP_TIERS = [
    (10_000, ActivityLevel("Excellent", "positive")),
    (7_500, ActivityLevel("Great", "positive")),
    (5_000, ActivityLevel("Good", "positive")),
    (2_500, ActivityLevel("Fair", "neutral")),
]
_LOW = ActivityLevel("Low", "neutral")


def classify_activity_level(
    features: DailyFeatures, assessment: RiskAssessment | None
) -> ActivityLevel:
    """The rule engine's verdict always wins over a good step count - a day
    with an escalate-level heart rate spike is never "Excellent" just
    because steps were also high that day."""
    if assessment is not None and assessment.level in _RISK_TIERS:
        return _RISK_TIERS[assessment.level]

    steps = features.steps or 0
    for threshold, level in _STEP_TIERS:
        if steps >= threshold:
            return level
    return _LOW
