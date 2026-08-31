from datetime import date, datetime, timedelta, timezone

from health_coach.features import aggregate_daily, aggregate_period, attach_baselines
from health_coach.models import DailyFeatures, SignalType, WearableSample


def _sample(patient_id, signal, value, day):
    return WearableSample(patient_id, signal, value, datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc))


def test_aggregate_daily_averages_resting_hr_sums_sleep_and_steps():
    day = date(2026, 1, 1)
    samples = [
        _sample("p1", SignalType.RESTING_HEART_RATE, 68, day),
        _sample("p1", SignalType.RESTING_HEART_RATE, 72, day),
        _sample("p1", SignalType.SLEEP_MINUTES, 240, day),
        _sample("p1", SignalType.SLEEP_MINUTES, 180, day),
        _sample("p1", SignalType.STEPS, 3000, day),
        _sample("p1", SignalType.STEPS, 2000, day),
    ]
    features = aggregate_daily("p1", day, samples)
    assert features.resting_hr == 70
    assert features.sleep_hours == 7.0
    assert features.steps == 5000


def test_attach_baselines_flags_deviation_from_stable_history():
    history = [
        DailyFeatures("p1", date(2026, 1, i + 1), resting_hr=70.0, sleep_hours=7.5, steps=7000)
        for i in range(10)
    ]
    today = DailyFeatures("p1", date(2026, 1, 11), resting_hr=130.0, sleep_hours=7.4, steps=7100)
    result = attach_baselines(today, history)
    assert result.hr_baseline == 70.0
    assert result.hr_zscore is not None and result.hr_zscore > 3
    assert result.sleep_zscore is not None and abs(result.sleep_zscore) < 1


def test_attach_baselines_skips_when_insufficient_history():
    history = [DailyFeatures("p1", date(2026, 1, 1), resting_hr=70.0)]
    today = DailyFeatures("p1", date(2026, 1, 2), resting_hr=95.0)
    result = attach_baselines(today, history)
    assert result.hr_baseline is None
    assert result.hr_zscore is None


# --- aggregate_period: daily/weekly/monthly rollups for the trend screen ---

def test_aggregate_period_daily_is_one_bucket_per_real_row():
    features = [
        DailyFeatures("p1", date(2026, 8, 24), resting_hr=60.0, steps=1000, calories=200.0),
        DailyFeatures("p1", date(2026, 8, 25), resting_hr=62.0, steps=2000, calories=210.0),
    ]
    buckets = aggregate_period(features, "daily")
    assert len(buckets) == 2
    assert buckets[0]["day_count"] == 1
    assert buckets[0]["period_start"] == buckets[0]["period_end"] == "2026-08-24"
    assert buckets[0]["steps"] == 1000


def test_aggregate_period_weekly_sums_steps_averages_heart_rate():
    # 2026-08-24 through 2026-08-30 is one full ISO week (Mon-Sun).
    hr_values = [60, 62, 64, 66, 68, 70, 72]
    steps_values = [1000, 2000, 3000, 4000, 5000, 6000, 7000]
    features = [
        DailyFeatures("p1", date(2026, 8, 24) + timedelta(days=i), resting_hr=hr, steps=st)
        for i, (hr, st) in enumerate(zip(hr_values, steps_values))
    ]
    buckets = aggregate_period(features, "weekly")
    assert len(buckets) == 1
    bucket = buckets[0]
    assert bucket["day_count"] == 7
    assert bucket["period_start"] == "2026-08-24"
    assert bucket["period_end"] == "2026-08-30"
    assert bucket["steps"] == sum(steps_values)  # summed: total activity for the week
    assert bucket["resting_hr"] == sum(hr_values) / len(hr_values)  # averaged: a vital sign


def test_aggregate_period_weekly_reports_partial_coverage_honestly():
    # Only Monday of the next ISO week has real data - day_count must say 1,
    # not silently imply a full week, and period bounds are still the full
    # calendar week (Mon-Sun) even though only one day of it is real.
    features = [DailyFeatures("p1", date(2026, 8, 31), steps=500)]
    buckets = aggregate_period(features, "weekly")
    assert len(buckets) == 1
    assert buckets[0]["day_count"] == 1
    assert buckets[0]["period_start"] == "2026-08-31"
    assert buckets[0]["period_end"] == "2026-09-06"
    assert buckets[0]["steps"] == 500


def test_aggregate_period_monthly_groups_by_calendar_month():
    features = [
        DailyFeatures("p1", date(2026, 8, 31), steps=1000, calories=100.0),
        DailyFeatures("p1", date(2026, 9, 1), steps=2000, calories=150.0),
        DailyFeatures("p1", date(2026, 9, 2), steps=3000, calories=200.0),
    ]
    buckets = aggregate_period(features, "monthly")
    assert len(buckets) == 2
    aug, sep = buckets
    assert aug["period_start"] == "2026-08-01"
    assert aug["period_end"] == "2026-08-31"
    assert aug["day_count"] == 1
    assert aug["steps"] == 1000
    assert sep["period_start"] == "2026-09-01"
    assert sep["period_end"] == "2026-09-30"
    assert sep["day_count"] == 2
    assert sep["steps"] == 5000
    assert sep["calories"] == 350.0


def test_aggregate_period_none_metric_stays_none_not_zero():
    features = [
        DailyFeatures("p1", date(2026, 8, 24), steps=1000, calories=None),
        DailyFeatures("p1", date(2026, 8, 25), steps=2000, calories=None),
    ]
    buckets = aggregate_period(features, "weekly")
    assert buckets[0]["calories"] is None  # not 0 - no real calorie data existed


def test_aggregate_period_rejects_unknown_period():
    try:
        aggregate_period([], "yearly")
        assert False, "expected ValueError"
    except ValueError:
        pass
