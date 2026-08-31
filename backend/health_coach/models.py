from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from enum import Enum


class SignalType(str, Enum):
    HEART_RATE = "heart_rate"
    RESTING_HEART_RATE = "resting_heart_rate"
    STEPS = "steps"
    SLEEP_MINUTES = "sleep_minutes"
    SPO2 = "spo2"
    SYMPTOM_FATIGUE = "symptom_fatigue"  # 0-10 self-reported scale
    CALORIES = "calories"  # active energy burned, kcal - Samsung Health/Health Connect ACTIVE_CALORIES_BURNED


@dataclass(frozen=True)
class WearableSample:
    patient_id: str
    signal: SignalType
    value: float
    timestamp: datetime
    source: str = "watch"


@dataclass
class DailyFeatures:
    patient_id: str
    day: date
    resting_hr: float | None = None
    sleep_hours: float | None = None
    steps: int | None = None
    fatigue_score: float | None = None
    calories: float | None = None

    hr_baseline: float | None = None
    hr_zscore: float | None = None
    sleep_baseline: float | None = None
    sleep_zscore: float | None = None
    steps_baseline: float | None = None
    steps_zscore: float | None = None
    calories_baseline: float | None = None
    calories_zscore: float | None = None


class RiskLevel(str, Enum):
    NORMAL = "normal"
    WATCH = "watch"
    ELEVATED = "elevated"
    ESCALATE = "escalate"


RISK_ORDER = {
    RiskLevel.NORMAL: 0,
    RiskLevel.WATCH: 1,
    RiskLevel.ELEVATED: 2,
    RiskLevel.ESCALATE: 3,
}


@dataclass(frozen=True)
class RuleHit:
    rule_id: str
    description: str
    risk_level: RiskLevel
    guideline_query: str | None = None


@dataclass
class RiskAssessment:
    patient_id: str
    day: date
    level: RiskLevel
    hits: list[RuleHit] = field(default_factory=list)

    @property
    def escalate(self) -> bool:
        return self.level == RiskLevel.ESCALATE


@dataclass
class GuidelineSnippet:
    guideline_id: str
    text: str
    evidence_level: str | None
    recommendation_grade: str | None
    score: float


@dataclass
class Recommendation:
    title: str
    body: str
    escalate: bool = False
    citations: list[GuidelineSnippet] = field(default_factory=list)
    rule_trace: list[RuleHit] = field(default_factory=list)


@dataclass(frozen=True)
class ChatTurn:
    patient_id: str
    role: str  # "user" | "coach"
    text: str
    timestamp: datetime
