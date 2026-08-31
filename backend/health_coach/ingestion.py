from __future__ import annotations

import csv
import random
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

from .models import SignalType, WearableSample


@dataclass
class PatientProfile:
    """Noise parameters (day-to-day physiological variability) are calibrated
    against LifeSnaps (Zenodo, DOI 10.5281/zenodo.6826682 - 71 adults, real
    Fitbit Sense data, median 88 days/person); see
    backend/scripts/calibrate_from_lifesnaps.py to reproduce. This supersedes
    the earlier MMASH-only calibration (backend/scripts/calibrate_from_mmash.py,
    22 adults, a single ~24-48h session each) for hr_noise and sleep_noise,
    and is the first real source for steps_noise at all - MMASH's
    single-session design structurally couldn't measure day-to-day step
    variability (no participant had 2+ full-wear days to compare).

    Like MMASH, LifeSnaps is a general/healthy-adult cohort, not oncology
    patients, so only the *noise* parameters are taken directly from it - the
    *baseline* levels stay clinically-informed placeholders for this patient
    population pending real pilot data or an oncology-specific cohort, per
    the caveat in rules.py. (For what it's worth, LifeSnaps' population means
    - ~66 bpm resting HR, ~8600 steps/day, ~7.4h sleep - are broadly
    consistent with the placeholder baselines below, which is reassuring but
    doesn't substitute for oncology-specific validation.)

    hr_noise=2.4: LifeSnaps' real within-person day-to-day resting-HR std
    (mean across 68 participants w/ 10+ days). Lower than MMASH's earlier
    rough estimate (~5 bpm from just 2 partial days/person) - genuine
    repeated-day data is more trustworthy than that few-partial-day proxy.
    sleep_noise=1.6: LifeSnaps' real within-person night-to-night sleep-hours
    std - supersedes the earlier MMASH-derived guess of 1.0, which was itself
    discounted from a single protocol-disrupted night.
    steps_noise=4500: LifeSnaps' real within-person day-to-day steps std -
    the previous value (1200) was an unvalidated guess; the real figure is
    notably higher, meaning day-to-day step counts vary a lot more than
    assumed.
    """

    patient_id: str
    baseline_resting_hr: float = 70.0
    baseline_sleep_hours: float = 7.5
    baseline_steps: int = 7000
    hr_noise: float = 2.4
    sleep_noise: float = 1.6
    steps_noise: float = 4500.0

    # Active-energy-burned calories, not total/BMR - matches what
    # HealthDataType.ACTIVE_ENERGY_BURNED / the app's Calories card actually
    # shows. No real calibration source for this one (LifeSnaps' calibration
    # above only covers hr/sleep/steps) - kept simple and steps-linked so it
    # moves the same direction steps do (a low-activity day has low active
    # calories too), rather than an independent, unrelated random walk.
    baseline_calories: float = 350.0
    calories_noise: float = 70.0


def generate_synthetic_day(
    profile: PatientProfile,
    day: date,
    rng: random.Random,
    anomaly: str | None = None,
) -> list[WearableSample]:
    """anomaly in {None, "tachycardia", "sleep_collapse", "inactivity"} - injects
    a realistic single-day deviation, useful for exercising the rule engine
    and for demoing escalation without needing a real device connected."""

    resting_hr = rng.gauss(profile.baseline_resting_hr, profile.hr_noise)
    sleep_hours = max(0.0, rng.gauss(profile.baseline_sleep_hours, profile.sleep_noise))
    steps = max(0, int(rng.gauss(profile.baseline_steps, profile.steps_noise)))

    if anomaly == "tachycardia":
        resting_hr += rng.uniform(35, 55)
    elif anomaly == "sleep_collapse":
        sleep_hours = rng.uniform(1.0, 3.0)
    elif anomaly == "inactivity":
        steps = rng.randint(50, 400)

    # Linked to how far steps deviated from this patient's own baseline, so
    # a low-steps day (inactivity anomaly included) shows correspondingly
    # low active calories instead of an unrelated independent number.
    calories = max(
        0.0,
        profile.baseline_calories
        + (steps - profile.baseline_steps) * 0.03
        + rng.gauss(0.0, profile.calories_noise),
    )

    ts = datetime.combine(day, time(hour=8), tzinfo=timezone.utc)
    return [
        WearableSample(profile.patient_id, SignalType.RESTING_HEART_RATE, round(resting_hr, 1), ts, "synthetic"),
        WearableSample(profile.patient_id, SignalType.SLEEP_MINUTES, round(sleep_hours * 60), ts, "synthetic"),
        WearableSample(profile.patient_id, SignalType.STEPS, steps, ts, "synthetic"),
        WearableSample(profile.patient_id, SignalType.CALORIES, round(calories, 1), ts, "synthetic"),
    ]


def generate_synthetic_history(
    profile: PatientProfile,
    start_day: date,
    n_days: int,
    seed: int = 42,
    anomaly_days: dict[int, str] | None = None,
) -> list[WearableSample]:
    rng = random.Random(seed)
    anomaly_days = anomaly_days or {}
    samples: list[WearableSample] = []
    for i in range(n_days):
        day = start_day + timedelta(days=i)
        samples.extend(generate_synthetic_day(profile, day, rng, anomaly=anomaly_days.get(i)))
    return samples


def load_samples_csv(path: Path, patient_id: str) -> list[WearableSample]:
    """Expects columns: timestamp,signal,value[,source]. Compatible with a
    simple export from a Health Connect / HealthKit dump script."""
    samples = []
    with Path(path).open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            samples.append(
                WearableSample(
                    patient_id=patient_id,
                    signal=SignalType(row["signal"]),
                    value=float(row["value"]),
                    timestamp=datetime.fromisoformat(row["timestamp"]),
                    source=row.get("source", "import"),
                )
            )
    return samples
