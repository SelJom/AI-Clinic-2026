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

# General (non-oncology-specific) evidence-based health reference - calories,
# macros, activity/steps, sleep, BMI, blood pressure, glucose, lipids, etc.
# Converted from rag.md (see scripts/convert_rag_md.py) into the same JSONL
# schema as GUIDELINES_PATH so it flows through the identical retrieval +
# grounding pipeline. Kept as a separate file rather than merged into the
# NCI extract, since it's a different kind of source (a consolidated
# reference the user assembled, not a raw scrape of one cited institutional
# page) - GuidelineStore loads both and treats them as one combined corpus.
GENERAL_HEALTH_REFERENCE_PATH = Path(
    os.environ.get(
        "HEALTH_COACH_GENERAL_REFERENCE_PATH",
        PROJECT_ROOT / "general_health_reference.jsonl",
    )
)

# Everything below is local-only by design: no external network calls unless
# a local Ollama daemon is explicitly reachable on this loopback address.
OLLAMA_URL = os.environ.get("HEALTH_COACH_OLLAMA_URL", "http://127.0.0.1:11434")
# Upgraded from llama3.2 (3B) after live testing on real hardware (an RTX
# 5070 Ti, 16GB VRAM) surfaced repeated instruction-following failures a
# small model is prone to (see README's "live-testing" sections). qwen2.5:14b
# fits comfortably (~9GB at the default Q4 quant) with real headroom to
# spare. Override with HEALTH_COACH_OLLAMA_MODEL if your hardware can't fit
# this - the deterministic bypasses and grounding checks in coach.py/
# llm_backends.py matter more than model size for correctness regardless of
# which model ends up running.
OLLAMA_MODEL = os.environ.get("HEALTH_COACH_OLLAMA_MODEL", "qwen2.5:14b")
OLLAMA_TIMEOUT_S = float(os.environ.get("HEALTH_COACH_OLLAMA_TIMEOUT_S", "0.6"))

API_HOST = os.environ.get("HEALTH_COACH_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("HEALTH_COACH_API_PORT", "8765"))

BASELINE_WINDOW_DAYS = int(os.environ.get("HEALTH_COACH_BASELINE_WINDOW_DAYS", "14"))
MIN_BASELINE_DAYS = int(os.environ.get("HEALTH_COACH_MIN_BASELINE_DAYS", "5"))
