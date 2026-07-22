from __future__ import annotations

import statistics
from collections import defaultdict
from datetime import date, datetime, timedelta

from . import config
from .models import DailyFeatures, SignalType, WearableSample

MAD_TO_STD = 1.4826  # scale factor making MAD a consistent estimator of std for normal data
MIN_STD_FLOOR = 1e-6


def aggregate_daily(patient_id: str, day: date, samples: list[WearableSample]) -> DailyFeatures:
    by_signal: dict[SignalType, list[float]] = defaultdict(list)
    for s in samples:
        by_signal[s.signal].append(s.value)

    resting_hr = None
    if by_signal[SignalType.RESTING_HEART_RATE]:
        resting_hr = statistics.mean(by_signal[SignalType.RESTING_HEART_RATE])
    elif by_signal[SignalType.HEART_RATE]:
        resting_hr = statistics.mean(sorted(by_signal[SignalType.HEART_RATE])[:5] or by_signal[SignalType.HEART_RATE])

    sleep_hours = None
    if by_signal[SignalType.SLEEP_MINUTES]:
        sleep_hours = sum(by_signal[SignalType.SLEEP_MINUTES]) / 60.0

    steps = None
    if by_signal[SignalType.STEPS]:
        steps = int(sum(by_signal[SignalType.STEPS]))

    fatigue_score = None
    if by_signal[SignalType.SYMPTOM_FATIGUE]:
        fatigue_score = statistics.mean(by_signal[SignalType.SYMPTOM_FATIGUE])

    return DailyFeatures(
        patient_id=patient_id,
        day=day,
        resting_hr=resting_hr,
        sleep_hours=sleep_hours,
        steps=steps,
        fatigue_score=fatigue_score,
    )


def robust_baseline(history: list[float]) -> tuple[float, float] | None:
    """Median/MAD baseline: resistant to the single bad night or the one high-HR
    outlier day that a mean/stdev baseline would get dragged around by."""
    if len(history) < config.MIN_BASELINE_DAYS:
        return None
    median = statistics.median(history)
    mad = statistics.median(abs(x - median) for x in history)
    # A relative floor (not just a tiny epsilon) matters here: a run of
    # identical-looking days gives mad == 0, and dividing by an epsilon
    # would turn a trivial deviation into a meaningless million-sigma spike.
    floor = max(abs(median) * 0.02, MIN_STD_FLOOR)
    std = max(mad * MAD_TO_STD, floor)
    return median, std


def zscore(value: float, baseline: tuple[float, float]) -> float:
    median, std = baseline
    return (value - median) / std


def attach_baselines(today: DailyFeatures, history: list[DailyFeatures]) -> DailyFeatures:
    window = history[-config.BASELINE_WINDOW_DAYS :]

    hr_hist = [f.resting_hr for f in window if f.resting_hr is not None]
    if today.resting_hr is not None and (baseline := robust_baseline(hr_hist)):
        today.hr_baseline, _ = baseline
        today.hr_zscore = zscore(today.resting_hr, baseline)

    sleep_hist = [f.sleep_hours for f in window if f.sleep_hours is not None]
    if today.sleep_hours is not None and (baseline := robust_baseline(sleep_hist)):
        today.sleep_baseline, _ = baseline
        today.sleep_zscore = zscore(today.sleep_hours, baseline)

    steps_hist = [f.steps for f in window if f.steps is not None]
    if today.steps is not None and (baseline := robust_baseline(steps_hist)):
        today.steps_baseline, _ = baseline
        today.steps_zscore = zscore(today.steps, baseline)

    return today


def group_samples_by_day(samples: list[WearableSample]) -> dict[date, list[WearableSample]]:
    by_day: dict[date, list[WearableSample]] = defaultdict(list)
    for s in samples:
        by_day[s.timestamp.date()].append(s)
    return by_day
