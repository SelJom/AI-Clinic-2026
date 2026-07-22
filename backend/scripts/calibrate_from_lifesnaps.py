"""Derives real within-person day-to-day variability for resting HR, steps,
and sleep duration from LifeSnaps (Zenodo, DOI 10.5281/zenodo.6826682 -
Yfantidou et al. 2022): 71 participants, Fitbit Sense, median 88 days each
(some over 240 days).

Unlike MMASH (backend/scripts/calibrate_from_mmash.py), which is a single
~24-48h session per participant, LifeSnaps gives many real days per person -
this is the actual source for `steps_noise` and `sleep_noise` in
`PatientProfile`, which MMASH's single-session design could never supply
(steps_noise) or could only approximate roughly (sleep_noise, and even then
confounded by protocol-driven overnight sampling).

Usage:
    1. Download from Zenodo (open, no login):
       https://zenodo.org/records/7229547/files/rais_anonymized.zip
    2. Unzip, then point this at csv_rais_anonymized/daily_fitbit_sema_df_unprocessed.csv
    3. python calibrate_from_lifesnaps.py /path/to/daily_fitbit_sema_df_unprocessed.csv
"""
from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

MIN_DAYS_PER_USER = 10  # need enough days to trust a per-person std estimate


def to_float(value: str) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def analyze(csv_path: Path) -> None:
    resting_hr = defaultdict(list)
    steps = defaultdict(list)
    sleep_hours = defaultdict(list)

    with csv_path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            uid = row["id"]

            hr = to_float(row.get("resting_hr"))
            if hr and 30 < hr < 130:  # drop obvious sensor artifacts
                resting_hr[uid].append(hr)

            st = to_float(row.get("steps"))
            if st is not None and st >= 0:
                steps[uid].append(st)

            sleep_ms = to_float(row.get("sleep_duration"))
            if sleep_ms and sleep_ms > 0:
                hours = sleep_ms / 3_600_000.0
                if 1.0 < hours < 14.0:  # drop obvious artifacts
                    sleep_hours[uid].append(hours)

    def summarize(name: str, per_user: dict[str, list[float]], fmt: str) -> None:
        user_means, user_stds = [], []
        for vals in per_user.values():
            if len(vals) < MIN_DAYS_PER_USER:
                continue
            user_means.append(statistics.mean(vals))
            user_stds.append(statistics.pstdev(vals))
        print(f"\n=== {name} (n={len(user_means)} participants with {MIN_DAYS_PER_USER}+ days) ===")
        print(f"population mean of per-user mean: {statistics.mean(user_means):{fmt}}")
        print(f"across-person std: {statistics.pstdev(user_means):{fmt}}")
        print(f"avg WITHIN-person day-to-day std (the real target): {statistics.mean(user_stds):{fmt}}")
        print(f"median within-person day-to-day std: {statistics.median(user_stds):{fmt}}")

    summarize("Resting HR (bpm)", resting_hr, ".2f")
    summarize("Daily steps", steps, ".0f")
    summarize("Nightly sleep (hours)", sleep_hours, ".2f")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path", type=Path, help="Path to daily_fitbit_sema_df_unprocessed.csv")
    args = parser.parse_args()
    analyze(args.csv_path)
