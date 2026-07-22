from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from .guidelines import GuidelineStore, get_default_store
from .models import (
    RISK_ORDER,
    DailyFeatures,
    Recommendation,
    RiskAssessment,
    RiskLevel,
    RuleHit,
)


@dataclass(frozen=True)
class Rule:
    rule_id: str
    description: str
    risk_level: RiskLevel
    predicate: Callable[[DailyFeatures], bool]
    guideline_query: str | None = None
    advice: str = ""


# Thresholds are intentionally conservative placeholders for a prototype, not
# validated clinical cutoffs. They should be reviewed by a clinician before
# this touches a real patient; the guideline citations below now come from
# NCI PDQ supportive-care summaries plus a dedicated cardio-oncology source
# for the tachycardia rules specifically (see README's "Guideline corpus
# provenance"), not the earlier ESMO staging corpus.
RULES: list[Rule] = [
    Rule(
        rule_id="tachycardia_severe",
        description="Resting heart rate is markedly elevated versus the patient's own baseline.",
        risk_level=RiskLevel.ESCALATE,
        # resting_hr > 120 sanity-checked against real cardiologist-annotated
        # arrhythmia data (MIT-BIH, PhysioNet; see
        # backend/scripts/analyze_mitbih_tachycardia.py): normal sinus rhythm
        # tops out around p90=107 bpm instantaneous, so 120 has real margin
        # above ordinary variation. But real ventricular-tachycardia episodes
        # in that data ranged as low as ~90 bpm (p10) - a single "> 120"
        # cutoff would miss some genuine tachyarrhythmias. That data is
        # continuous ECG from arrhythmia patients, not daily wrist-derived
        # resting HR from cancer patients, so treat this as a loose
        # plausibility check on magnitude, not validation of sensitivity.
        predicate=lambda f: f.resting_hr is not None
        and (f.resting_hr > 120 or (f.hr_zscore is not None and f.hr_zscore > 3.5)),
        guideline_query="cardiac monitoring symptoms treatment toxicity",
        advice="Your resting heart rate today is well above your usual pattern. Please contact your care team today.",
    ),
    Rule(
        rule_id="tachycardia_moderate",
        description="Resting heart rate is persistently above the patient's baseline.",
        risk_level=RiskLevel.ELEVATED,
        # Bounded above by the severe thresholds so a single reading only ever
        # fires one tachycardia rule instead of stacking both severities.
        predicate=lambda f: f.resting_hr is not None
        and f.hr_zscore is not None
        and 2.5 < f.hr_zscore <= 3.5
        and 100 < f.resting_hr <= 120,
        guideline_query="cardiac monitoring symptoms treatment toxicity",
        advice="Your resting heart rate is higher than your recent normal. Rest, hydrate, and monitor over the next day.",
    ),
    Rule(
        rule_id="sleep_collapse",
        description="Sleep duration is critically low or far below baseline.",
        risk_level=RiskLevel.ELEVATED,
        predicate=lambda f: f.sleep_hours is not None
        and (f.sleep_hours < 4 or (f.sleep_zscore is not None and f.sleep_zscore < -2.5)),
        guideline_query="sleep fatigue quality of life supportive care",
        advice="Your sleep was much shorter than usual. Poor sleep can worsen fatigue during treatment - consider an earlier wind-down tonight and mention this at your next visit if it continues.",
    ),
    Rule(
        rule_id="profound_inactivity",
        description="Activity level dropped sharply and is unusually low.",
        risk_level=RiskLevel.WATCH,
        predicate=lambda f: f.steps is not None
        and f.steps < 500
        and f.steps_zscore is not None
        and f.steps_zscore < -2,
        guideline_query="physical activity fatigue rehabilitation",
        advice="You were much less active than usual today. If this is due to fatigue or discomfort, gentle movement can help, but let your care team know if it persists.",
    ),
    Rule(
        rule_id="high_self_reported_fatigue",
        description="Self-reported fatigue score is high.",
        risk_level=RiskLevel.WATCH,
        predicate=lambda f: f.fatigue_score is not None and f.fatigue_score >= 7,
        guideline_query="fatigue management supportive care quality of life",
        advice="You reported significant fatigue today. Prioritize rest, and flag this to your care team if it lasts more than a couple of days.",
    ),
]


def evaluate(features: DailyFeatures, rules: list[Rule] = RULES) -> RiskAssessment:
    hits = [
        RuleHit(
            rule_id=r.rule_id,
            description=r.description,
            risk_level=r.risk_level,
            guideline_query=r.guideline_query,
        )
        for r in rules
        if r.predicate(features)
    ]
    level = max((h.risk_level for h in hits), key=lambda lvl: RISK_ORDER[lvl], default=RiskLevel.NORMAL)
    return RiskAssessment(patient_id=features.patient_id, day=features.day, level=level, hits=hits)


def build_recommendations(
    features: DailyFeatures,
    assessment: RiskAssessment,
    rules: list[Rule] = RULES,
    store: GuidelineStore | None = None,
) -> list[Recommendation]:
    store = store or get_default_store()
    rules_by_id = {r.rule_id: r for r in rules}

    if not assessment.hits:
        return [
            Recommendation(
                title="You're on track today",
                body="Your heart rate, sleep, and activity all look consistent with your recent baseline. Keep up your routine.",
                escalate=False,
            )
        ]

    recommendations = []
    for hit in assessment.hits:
        rule = rules_by_id[hit.rule_id]
        citations = store.retrieve(rule.guideline_query, k=2) if rule.guideline_query else []
        recommendations.append(
            Recommendation(
                title=hit.description,
                body=rule.advice,
                escalate=hit.risk_level == RiskLevel.ESCALATE,
                citations=citations,
                rule_trace=[hit],
            )
        )
    return recommendations
