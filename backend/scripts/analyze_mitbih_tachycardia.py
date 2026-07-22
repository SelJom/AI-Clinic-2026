"""Sanity-checks the `tachycardia_severe`/`tachycardia_moderate` cutoffs in
rules.py (resting_hr > 120 / 100-120 bpm) against real, cardiologist-
annotated arrhythmia data: the MIT-BIH Arrhythmia Database (PhysioNet, open
access, DOI 10.13026/C2F305 - 48 ambulatory ECG records, ~110,000 annotated
beats).

Important scope limits, so this isn't over-claimed as validation:
  - This is continuous ECG from hospital/ambulatory arrhythmia patients in
    the 1970s-80s, not once-daily wrist-derived resting HR from ambulatory
    cancer patients today. Different modality, different population,
    different measurement cadence. Treat this as a loose plausibility check
    on the *magnitude* of the cutoff, not clinical validation.
  - Instantaneous beat-to-beat HR (60 / RR-interval) is not the same
    quantity as a smoothed "resting HR" summary.

Requires the `wfdb` package (pip install wfdb) - not part of the core
dependency-free backend, only needed to parse PhysioNet's WFDB signal format
for this one-off analysis.

Usage:
    1. Download (no login): https://physionet.org/content/mitdb/1.0.0/
    2. Unzip, then: python analyze_mitbih_tachycardia.py /path/to/mit-bih-arrhythmia-database-1.0.0
"""
from __future__ import annotations

import argparse
import statistics
from pathlib import Path

import wfdb

RECORDS = [
    "100", "101", "102", "103", "104", "105", "106", "107", "108", "109",
    "111", "112", "113", "114", "115", "116", "117", "118", "119", "121",
    "122", "123", "124", "200", "201", "202", "203", "205", "207", "208",
    "209", "210", "212", "213", "214", "215", "217", "219", "220", "221",
    "222", "223", "228", "230", "231", "232", "233", "234",
]

# Actual QRS beat annotation symbols (as opposed to '+' rhythm-change markers).
BEAT_SYMBOLS = set("NLRBAaJSVrFejnQ?")

# The rhythm labels we care about for a tachycardia sanity check. See the
# MIT-BIH annotator's guide for the full rhythm-label vocabulary - note "T"
# means ventricular *trigeminy* (a beat-pattern label), not tachycardia.
RHYTHMS_OF_INTEREST = {"N", "VT", "SVTA", "AFIB", "AFL"}

MIN_RR_SECONDS = 0.2  # drops implausible/artifactual intervals
MAX_RR_SECONDS = 3.0


def collect_hr_by_rhythm(data_dir: Path) -> dict[str, list[float]]:
    hr_by_rhythm: dict[str, list[float]] = {r: [] for r in RHYTHMS_OF_INTEREST}

    for rec in RECORDS:
        ann = wfdb.rdann(str(data_dir / rec), "atr")
        fs = ann.fs
        current_rhythm = None
        prev_beat_sample = None

        for sample, sym, aux in zip(ann.sample, ann.symbol, ann.aux_note):
            if sym == "+":
                current_rhythm = aux.strip("\x00").lstrip("(")
                prev_beat_sample = None  # don't bridge RR across a rhythm change
                continue
            if sym in BEAT_SYMBOLS:
                if prev_beat_sample is not None and current_rhythm in hr_by_rhythm:
                    rr_seconds = (sample - prev_beat_sample) / fs
                    if MIN_RR_SECONDS < rr_seconds < MAX_RR_SECONDS:
                        hr_by_rhythm[current_rhythm].append(60.0 / rr_seconds)
                prev_beat_sample = sample

    return hr_by_rhythm


def summarize(hr_by_rhythm: dict[str, list[float]]) -> None:
    for rhythm, hrs in hr_by_rhythm.items():
        if not hrs:
            print(f"{rhythm}: no data")
            continue
        deciles = statistics.quantiles(hrs, n=10)
        print(
            f"{rhythm}: n={len(hrs)} mean={statistics.mean(hrs):.1f} "
            f"median={statistics.median(hrs):.1f} p10={deciles[0]:.1f} "
            f"p90={deciles[-1]:.1f} min={min(hrs):.1f} max={max(hrs):.1f}"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("data_dir", type=Path, help="Path to the extracted mit-bih-arrhythmia-database-1.0.0 folder")
    args = parser.parse_args()
    summarize(collect_hr_by_rhythm(args.data_dir))
