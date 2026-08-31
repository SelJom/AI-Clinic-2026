from __future__ import annotations

import calendar
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

    calories = None
    if by_signal[SignalType.CALORIES]:
        calories = sum(by_signal[SignalType.CALORIES])

    return DailyFeatures(
        patient_id=patient_id,
        day=day,
        resting_hr=resting_hr,
        sleep_hours=sleep_hours,
        steps=steps,
        fatigue_score=fatigue_score,
        calories=calories,
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

    calories_hist = [f.calories for f in window if f.calories is not None]
    if today.calories is not None and (baseline := robust_baseline(calories_hist)):
        today.calories_baseline, _ = baseline
        today.calories_zscore = zscore(today.calories, baseline)

    return today


def _avg(values: list[float | None]) -> float | None:
    real = [v for v in values if v is not None]
    return statistics.mean(real) if real else None


def _total(values: list[float | None]) -> float | None:
    real = [v for v in values if v is not None]
    return sum(real) if real else None


def _week_bounds(iso_year: int, iso_week: int) -> tuple[date, date]:
    return date.fromisocalendar(iso_year, iso_week, 1), date.fromisocalendar(iso_year, iso_week, 7)


def _month_bounds(year: int, month: int) -> tuple[date, date]:
    last_day = calendar.monthrange(year, month)[1]
    return date(year, month, 1), date(year, month, last_day)


def aggregate_period(features: list[DailyFeatures], period: str) -> list[dict]:
    """Groups real daily rows into weekly/monthly buckets for the trend
    screen's daily/weekly/monthly toggle. Steps and calories are *summed*
    (total activity for the period is the meaningful number); resting HR
    and sleep are *averaged* (summing a vital sign across a week doesn't
    mean anything). `period_start`/`period_end` are the full calendar
    week/month even if only some days in it have real data - `day_count`
    says exactly how many real days actually back the number, rather than
    silently implying a full week/month of coverage when there wasn't one.
    """
    if period == "daily":
        return [
            {
                "period_start": f.day.isoformat(),
                "period_end": f.day.isoformat(),
                "day_count": 1,
                "resting_hr": f.resting_hr,
                "sleep_hours": f.sleep_hours,
                "steps": f.steps,
                "calories": f.calories,
            }
            for f in features
        ]
    if period not in ("weekly", "monthly"):
        raise ValueError(f"unknown period: {period!r}")

    groups: dict[tuple[int, int], list[DailyFeatures]] = defaultdict(list)
    for f in features:
        key = f.day.isocalendar()[:2] if period == "weekly" else (f.day.year, f.day.month)
        groups[key].append(f)

    buckets = []
    for key in sorted(groups):
        rows = groups[key]
        start, end = _week_bounds(*key) if period == "weekly" else _month_bounds(*key)
        buckets.append(
            {
                "period_start": start.isoformat(),
                "period_end": end.isoformat(),
                "day_count": len(rows),
                "resting_hr": _avg([r.resting_hr for r in rows]),
                "sleep_hours": _avg([r.sleep_hours for r in rows]),
                "steps": _total([r.steps for r in rows]),
                "calories": _total([r.calories for r in rows]),
            }
        )
    return buckets


def group_samples_by_day(samples: list[WearableSample]) -> dict[date, list[WearableSample]]:
    by_day: dict[date, list[WearableSample]] = defaultdict(list)
    for s in samples:
        by_day[s.timestamp.date()].append(s)
    return by_day
