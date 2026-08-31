from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path

from . import config
from .models import (
    ChatTurn,
    DailyFeatures,
    RiskAssessment,
    RiskLevel,
    RuleHit,
    SignalType,
    WearableSample,
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    patient_id TEXT NOT NULL,
    signal TEXT NOT NULL,
    value REAL NOT NULL,
    timestamp TEXT NOT NULL,
    source TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_patient_signal
    ON samples (patient_id, signal, timestamp);

CREATE TABLE IF NOT EXISTS daily_features (
    patient_id TEXT NOT NULL,
    day TEXT NOT NULL,
    resting_hr REAL,
    sleep_hours REAL,
    steps INTEGER,
    fatigue_score REAL,
    calories REAL,
    hr_baseline REAL,
    hr_zscore REAL,
    sleep_baseline REAL,
    sleep_zscore REAL,
    steps_baseline REAL,
    steps_zscore REAL,
    calories_baseline REAL,
    calories_zscore REAL,
    PRIMARY KEY (patient_id, day)
);

CREATE TABLE IF NOT EXISTS risk_assessments (
    patient_id TEXT NOT NULL,
    day TEXT NOT NULL,
    level TEXT NOT NULL,
    hits_json TEXT NOT NULL,
    PRIMARY KEY (patient_id, day)
);

CREATE TABLE IF NOT EXISTS chat_history (
    patient_id TEXT NOT NULL,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    timestamp TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_patient ON chat_history (patient_id, timestamp);
"""


@contextmanager
def connect(db_path: Path | None = None):
    path = db_path or config.DB_PATH
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# New columns added to daily_features after this table already existed in
# real running databases (this project's own local.db included) - a bare
# "CREATE TABLE IF NOT EXISTS" is a no-op against an existing table, so new
# columns need an explicit, idempotent migration rather than just editing
# SCHEMA above (which only helps brand-new databases).
_DAILY_FEATURES_MIGRATIONS = [
    ("calories", "REAL"),
    ("calories_baseline", "REAL"),
    ("calories_zscore", "REAL"),
]


def _migrate_daily_features_columns(conn: sqlite3.Connection) -> None:
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(daily_features)")}
    for column, coltype in _DAILY_FEATURES_MIGRATIONS:
        if column not in existing:
            conn.execute(f"ALTER TABLE daily_features ADD COLUMN {column} {coltype}")


def init_db(db_path: Path | None = None) -> None:
    with connect(db_path) as conn:
        conn.executescript(SCHEMA)
        _migrate_daily_features_columns(conn)


def save_samples(samples: list[WearableSample], db_path: Path | None = None) -> None:
    with connect(db_path) as conn:
        conn.executemany(
            "INSERT INTO samples (patient_id, signal, value, timestamp, source) "
            "VALUES (?, ?, ?, ?, ?)",
            [
                (s.patient_id, s.signal.value, s.value, s.timestamp.isoformat(), s.source)
                for s in samples
            ],
        )


def load_samples(
    patient_id: str,
    signal: SignalType,
    since: datetime,
    until: datetime,
    db_path: Path | None = None,
) -> list[WearableSample]:
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM samples WHERE patient_id = ? AND signal = ? "
            "AND timestamp >= ? AND timestamp < ? ORDER BY timestamp",
            (patient_id, signal.value, since.isoformat(), until.isoformat()),
        ).fetchall()
    return [
        WearableSample(
            patient_id=r["patient_id"],
            signal=SignalType(r["signal"]),
            value=r["value"],
            timestamp=datetime.fromisoformat(r["timestamp"]),
            source=r["source"],
        )
        for r in rows
    ]


def save_daily_features(features: DailyFeatures, db_path: Path | None = None) -> None:
    with connect(db_path) as conn:
        conn.execute(
            """
            INSERT INTO daily_features (
                patient_id, day, resting_hr, sleep_hours, steps, fatigue_score, calories,
                hr_baseline, hr_zscore, sleep_baseline, sleep_zscore,
                steps_baseline, steps_zscore, calories_baseline, calories_zscore
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (patient_id, day) DO UPDATE SET
                resting_hr = excluded.resting_hr,
                sleep_hours = excluded.sleep_hours,
                steps = excluded.steps,
                fatigue_score = excluded.fatigue_score,
                calories = excluded.calories,
                hr_baseline = excluded.hr_baseline,
                hr_zscore = excluded.hr_zscore,
                sleep_baseline = excluded.sleep_baseline,
                sleep_zscore = excluded.sleep_zscore,
                steps_baseline = excluded.steps_baseline,
                steps_zscore = excluded.steps_zscore,
                calories_baseline = excluded.calories_baseline,
                calories_zscore = excluded.calories_zscore
            """,
            (
                features.patient_id,
                features.day.isoformat(),
                features.resting_hr,
                features.sleep_hours,
                features.steps,
                features.fatigue_score,
                features.calories,
                features.hr_baseline,
                features.hr_zscore,
                features.sleep_baseline,
                features.sleep_zscore,
                features.steps_baseline,
                features.steps_zscore,
                features.calories_baseline,
                features.calories_zscore,
            ),
        )


def load_recent_daily_features(
    patient_id: str, before: date, limit_days: int, db_path: Path | None = None
) -> list[DailyFeatures]:
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM daily_features WHERE patient_id = ? AND day < ? "
            "ORDER BY day DESC LIMIT ?",
            (patient_id, before.isoformat(), limit_days),
        ).fetchall()
    rows = list(reversed(rows))
    return [
        DailyFeatures(
            patient_id=r["patient_id"],
            day=date.fromisoformat(r["day"]),
            resting_hr=r["resting_hr"],
            sleep_hours=r["sleep_hours"],
            steps=r["steps"],
            fatigue_score=r["fatigue_score"],
            calories=r["calories"],
            hr_baseline=r["hr_baseline"],
            hr_zscore=r["hr_zscore"],
            sleep_baseline=r["sleep_baseline"],
            sleep_zscore=r["sleep_zscore"],
            steps_baseline=r["steps_baseline"],
            steps_zscore=r["steps_zscore"],
            calories_baseline=r["calories_baseline"],
            calories_zscore=r["calories_zscore"],
        )
        for r in rows
    ]


def save_risk_assessment(assessment: RiskAssessment, db_path: Path | None = None) -> None:
    hits_json = json.dumps(
        [
            {
                "rule_id": h.rule_id,
                "description": h.description,
                "risk_level": h.risk_level.value,
                "guideline_query": h.guideline_query,
            }
            for h in assessment.hits
        ]
    )
    with connect(db_path) as conn:
        conn.execute(
            """
            INSERT INTO risk_assessments (patient_id, day, level, hits_json)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (patient_id, day) DO UPDATE SET
                level = excluded.level, hits_json = excluded.hits_json
            """,
            (assessment.patient_id, assessment.day.isoformat(), assessment.level.value, hits_json),
        )


def load_latest_risk_assessment(
    patient_id: str, db_path: Path | None = None
) -> RiskAssessment | None:
    with connect(db_path) as conn:
        row = conn.execute(
            "SELECT * FROM risk_assessments WHERE patient_id = ? "
            "ORDER BY day DESC LIMIT 1",
            (patient_id,),
        ).fetchone()
    return _row_to_assessment(row)


def load_risk_assessment_for_day(
    patient_id: str, day: date, db_path: Path | None = None
) -> RiskAssessment | None:
    with connect(db_path) as conn:
        row = conn.execute(
            "SELECT * FROM risk_assessments WHERE patient_id = ? AND day = ?",
            (patient_id, day.isoformat()),
        ).fetchone()
    return _row_to_assessment(row)


def load_recent_risk_assessments(
    patient_id: str, before: date, limit_days: int, db_path: Path | None = None
) -> list[RiskAssessment]:
    """Mirrors load_recent_daily_features's window (day < before, oldest to
    newest) so callers can zip the two together per day."""
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM risk_assessments WHERE patient_id = ? AND day < ? "
            "ORDER BY day DESC LIMIT ?",
            (patient_id, before.isoformat(), limit_days),
        ).fetchall()
    rows = list(reversed(rows))
    return [a for a in (_row_to_assessment(r) for r in rows) if a is not None]


def _row_to_assessment(row: sqlite3.Row | None) -> RiskAssessment | None:
    if row is None:
        return None
    hits = [
        RuleHit(
            rule_id=h["rule_id"],
            description=h["description"],
            risk_level=RiskLevel(h["risk_level"]),
            guideline_query=h["guideline_query"],
        )
        for h in json.loads(row["hits_json"])
    ]
    return RiskAssessment(
        patient_id=row["patient_id"],
        day=date.fromisoformat(row["day"]),
        level=RiskLevel(row["level"]),
        hits=hits,
    )


def delete_patient_data(patient_id: str, db_path: Path | None = None) -> dict[str, int]:
    """Erases every row for a patient across all local tables - the
    technical half of a right-to-erasure request. Returns a per-table count
    of rows removed so the caller (CLI/API) can confirm what happened
    rather than deleting silently."""
    tables = ["samples", "daily_features", "risk_assessments", "chat_history"]
    counts: dict[str, int] = {}
    with connect(db_path) as conn:
        for table in tables:
            cur = conn.execute(f"DELETE FROM {table} WHERE patient_id = ?", (patient_id,))
            counts[table] = cur.rowcount
    return counts


def export_patient_data(patient_id: str, db_path: Path | None = None) -> dict:
    """Everything stored locally for a patient, as plain dicts - the
    technical half of a right-to-access/data-portability request. Not
    filtered or summarized; this is the raw local record."""
    with connect(db_path) as conn:
        samples = conn.execute(
            "SELECT * FROM samples WHERE patient_id = ? ORDER BY timestamp", (patient_id,)
        ).fetchall()
        daily_features = conn.execute(
            "SELECT * FROM daily_features WHERE patient_id = ? ORDER BY day", (patient_id,)
        ).fetchall()
        risk_assessments = conn.execute(
            "SELECT * FROM risk_assessments WHERE patient_id = ? ORDER BY day", (patient_id,)
        ).fetchall()
        chat_history = conn.execute(
            "SELECT * FROM chat_history WHERE patient_id = ? ORDER BY timestamp", (patient_id,)
        ).fetchall()
    return {
        "patient_id": patient_id,
        "samples": [dict(r) for r in samples],
        "daily_features": [dict(r) for r in daily_features],
        "risk_assessments": [dict(r) for r in risk_assessments],
        "chat_history": [dict(r) for r in chat_history],
    }


def save_chat_turn(turn: ChatTurn, db_path: Path | None = None) -> None:
    with connect(db_path) as conn:
        conn.execute(
            "INSERT INTO chat_history (patient_id, role, text, timestamp) VALUES (?, ?, ?, ?)",
            (turn.patient_id, turn.role, turn.text, turn.timestamp.isoformat()),
        )


def load_chat_history(
    patient_id: str, limit: int = 20, db_path: Path | None = None
) -> list[ChatTurn]:
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM chat_history WHERE patient_id = ? "
            "ORDER BY timestamp DESC LIMIT ?",
            (patient_id, limit),
        ).fetchall()
    rows = list(reversed(rows))
    return [
        ChatTurn(
            patient_id=r["patient_id"],
            role=r["role"],
            text=r["text"],
            timestamp=datetime.fromisoformat(r["timestamp"]),
        )
        for r in rows
    ]
