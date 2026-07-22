from __future__ import annotations

import os
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = BACKEND_DIR.parent

DATA_DIR = Path(os.environ.get("HEALTH_COACH_DATA_DIR", BACKEND_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = Path(os.environ.get("HEALTH_COACH_DB_PATH", DATA_DIR / "local.db"))

GUIDELINES_PATH = Path(
    os.environ.get(
        "HEALTH_COACH_GUIDELINES_PATH",
        PROJECT_ROOT / "nci_pdq_supportive_care_recommendations_clean.jsonl",
    )
)

# Everything below is local-only by design: no external network calls unless
# a local Ollama daemon is explicitly reachable on this loopback address.
OLLAMA_URL = os.environ.get("HEALTH_COACH_OLLAMA_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("HEALTH_COACH_OLLAMA_MODEL", "llama3.2")
OLLAMA_TIMEOUT_S = float(os.environ.get("HEALTH_COACH_OLLAMA_TIMEOUT_S", "0.6"))

API_HOST = os.environ.get("HEALTH_COACH_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("HEALTH_COACH_API_PORT", "8765"))

BASELINE_WINDOW_DAYS = int(os.environ.get("HEALTH_COACH_BASELINE_WINDOW_DAYS", "14"))
MIN_BASELINE_DAYS = int(os.environ.get("HEALTH_COACH_MIN_BASELINE_DAYS", "5"))
