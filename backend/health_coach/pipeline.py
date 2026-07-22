from __future__ import annotations

from dataclasses import dataclass
from datetime import date

from . import storage
from .features import aggregate_daily, attach_baselines, group_samples_by_day
from .guidelines import GuidelineStore
from .models import DailyFeatures, Recommendation, RiskAssessment, WearableSample
from .rules import Rule, RULES, build_recommendations, evaluate


@dataclass
class DailyResult:
    features: DailyFeatures
    assessment: RiskAssessment
    recommendations: list[Recommendation]


def process_day(
    patient_id: str,
    day: date,
    samples: list[WearableSample],
    rules: list[Rule] = RULES,
    guideline_store: GuidelineStore | None = None,
    db_path=None,
) -> DailyResult:
    history = storage.load_recent_daily_features(patient_id, before=day, limit_days=30, db_path=db_path)

    today = aggregate_daily(patient_id, day, samples)
    today = attach_baselines(today, history)

    assessment = evaluate(today, rules)
    recommendations = build_recommendations(today, assessment, rules, guideline_store)

    storage.save_daily_features(today, db_path=db_path)
    storage.save_risk_assessment(assessment, db_path=db_path)

    return DailyResult(features=today, assessment=assessment, recommendations=recommendations)


def process_samples(
    patient_id: str,
    samples: list[WearableSample],
    rules: list[Rule] = RULES,
    guideline_store: GuidelineStore | None = None,
    db_path=None,
) -> list[DailyResult]:
    """Ingests a batch of raw samples spanning any number of days, replaying
    day-by-day so each day's baseline only sees days strictly before it -
    the same causal order a continuously running phone app would see."""
    storage.save_samples(samples, db_path=db_path)
    by_day = group_samples_by_day(samples)

    results = []
    for day in sorted(by_day):
        result = process_day(patient_id, day, by_day[day], rules, guideline_store, db_path=db_path)
        results.append(result)
    return results
