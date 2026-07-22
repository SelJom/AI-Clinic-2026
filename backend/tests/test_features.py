from datetime import date, datetime, timezone

from health_coach.features import aggregate_daily, attach_baselines
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
