"""Derive realistic wearable-signal statistics from MMASH (PhysioNet, open
access, ODbL license, DOI 10.13026/cerq-fc86 - Rossi et al. 2020) and print
them so the constants in `health_coach.ingestion.PatientProfile` can be
sanity-checked against real device data instead of hand-picked guesses.

MMASH is 22 healthy adults with a single ~24-48h continuous Actigraph
recording (HR, steps, sleep-stage inclinometer) plus one sleep-diary night
each. That makes it useful for:
  - population-level baseline distributions (typical resting HR, one night
    of sleep, a full day of steps for a healthy adult), and
  - a rough read on physiological noise magnitude,
but NOT for validated within-person day-to-day variability, since no
participant has more than a couple of partial days of data. It is also a
*healthy young-adult* cohort, not oncology patients - treat any "baseline
level" numbers here as a sanity check, not a replacement for the clinically
relevant (lower activity, more fatigue) baseline this app actually targets.

Usage:
    1. Download the dataset yourself (no login required):
       https://physionet.org/content/mmash/1.0.0/
    2. Unzip it, then unzip the nested MMASH.zip inside it.
    3. python calibrate_from_mmash.py /path/to/DataPaper
"""
from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

FULL_DAY_SECONDS = 10 * 3600  # min device-wear time to count a day as "full"


def analyze(data_paper_dir: Path) -> None:
    per_user_resting_hr_daily: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    per_user_steps_daily: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    per_user_wear_seconds_daily: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    per_user_sleep_minutes: dict[str, float] = defaultdict(float)

    user_dirs = sorted(p for p in data_paper_dir.iterdir() if p.is_dir() and p.name.startswith("user_"))
    if not user_dirs:
        raise SystemExit(f"No user_* folders found under {data_paper_dir} - did you unzip MMASH.zip?")

    for user_dir in user_dirs:
        uid = user_dir.name

        actigraph = user_dir / "Actigraph.csv"
        if actigraph.exists():
            with actigraph.open(newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    day = row["day"]
                    try:
                        hr = float(row["HR"])
                        steps = int(float(row["Steps"]))
                        lying = row.get("Inclinometer Lying", "0") == "1"
                    except (ValueError, KeyError):
                        continue
                    if hr > 0 and lying:
                        per_user_resting_hr_daily[uid][day].append(hr)
                    per_user_steps_daily[uid][day] += steps
                    per_user_wear_seconds_daily[uid][day] += 1

        for day, seconds in list(per_user_wear_seconds_daily[uid].items()):
            if seconds < FULL_DAY_SECONDS:
                per_user_steps_daily[uid].pop(day, None)

        sleep_csv = user_dir / "sleep.csv"
        if sleep_csv.exists():
            with sleep_csv.open(newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    try:
                        per_user_sleep_minutes[uid] += float(row["Total Sleep Time (TST)"])
                    except (ValueError, KeyError):
                        continue

    user_mean_hr, user_std_hr = [], []
    for days in per_user_resting_hr_daily.values():
        daily_means = [statistics.mean(v) for v in days.values() if v]
        if len(daily_means) >= 2:
            user_mean_hr.append(statistics.mean(daily_means))
            user_std_hr.append(statistics.pstdev(daily_means))

    user_mean_steps, user_std_steps = [], []
    for days in per_user_steps_daily.values():
        vals = [v for v in days.values() if v > 0]
        if not vals:
            continue
        user_mean_steps.append(statistics.mean(vals))
        if len(vals) >= 2:
            user_std_steps.append(statistics.pstdev(vals))

    nightly_sleep_h = [m / 60.0 for m in per_user_sleep_minutes.values() if m >= 60]

    print(f"participants found: {len(user_dirs)}\n")

    print("=== Resting HR (bpm), lying-state samples only ===")
    print(f"n={len(user_mean_hr)}  population mean: {statistics.mean(user_mean_hr):.1f}"
          f"  across-person std: {statistics.pstdev(user_mean_hr):.1f}")
    print(f"avg within-person day-to-day std (rough, few days/person): {statistics.mean(user_std_hr):.2f}\n")

    print("=== Daily steps, full-wear days only ===")
    print(f"n={len(user_mean_steps)}  population mean: {statistics.mean(user_mean_steps):.0f}"
          f"  across-person std: {statistics.pstdev(user_mean_steps):.0f}")
    if user_std_steps:
        print(f"avg within-person day-to-day std (n={len(user_std_steps)} users w/ 2+ full days): "
              f"{statistics.mean(user_std_steps):.0f}\n")
    else:
        print("within-person day-to-day std: not derivable (no user has 2+ full-wear days)\n")

    print("=== Single-night sleep (hours), one monitored night per participant ===")
    print(f"n={len(nightly_sleep_h)}  population mean: {statistics.mean(nightly_sleep_h):.2f}"
          f"  across-person std: {statistics.pstdev(nightly_sleep_h):.2f}")
    print("Note: MMASH's protocol includes periodic overnight saliva sampling, which "
          "fragments the monitored night - treat this mean as a lower bound on natural "
          "sleep duration, not a general population norm.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("data_paper_dir", type=Path, help="Path to the extracted MMASH 'DataPaper' folder")
    args = parser.parse_args()
    analyze(args.data_paper_dir)
