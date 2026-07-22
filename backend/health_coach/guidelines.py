from __future__ import annotations

import json
import math
import re
from collections import Counter
from functools import lru_cache
from pathlib import Path

from . import config
from .models import GuidelineSnippet

_TOKEN_RE = re.compile(r"[a-zA-Z][a-zA-Z\-]+")

_STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "should", "are", "was", "were",
    "from", "who", "may", "can", "not", "have", "has", "had", "been", "being",
    "its", "their", "than", "then", "into", "onto", "such", "also", "used",
    "based", "these", "those", "which", "when", "where", "there",
}


def tokenize(text: str) -> list[str]:
    return [t.lower() for t in _TOKEN_RE.findall(text) if t.lower() not in _STOPWORDS and len(t) > 2]


class GuidelineStore:
    """Local TF-IDF / cosine-similarity retriever over the extracted guideline
    corpus. Deliberately dependency-free (no sklearn/embedding download) so
    it works fully offline out of the box; swap in a sentence-transformers
    backend later if semantic recall on paraphrased queries becomes the
    bottleneck.
    """

    def __init__(self, path: Path):
        self.path = path
        self.docs: list[dict] = []
        self._doc_vectors: list[dict[str, float]] = []
        self._idf: dict[str, float] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            raise FileNotFoundError(f"Guideline corpus not found at {self.path}")

        with self.path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                self.docs.append(json.loads(line))

        doc_tokens = [tokenize(d["text"]) for d in self.docs]
        n_docs = len(self.docs)
        df: Counter[str] = Counter()
        for tokens in doc_tokens:
            for t in set(tokens):
                df[t] += 1
        self._idf = {t: math.log((n_docs + 1) / (c + 1)) + 1.0 for t, c in df.items()}
        self._doc_vectors = [self._vectorize(tokens) for tokens in doc_tokens]

    def _vectorize(self, tokens: list[str], is_query: bool = False) -> dict[str, float]:
        if not tokens:
            return {}
        tf = Counter(tokens)
        length = len(tokens)
        default_idf = math.log(len(self.docs) + 1) + 1.0 if is_query else 0.0
        vec = {t: (count / length) * self._idf.get(t, default_idf) for t, count in tf.items()}
        norm = math.sqrt(sum(v * v for v in vec.values())) or 1.0
        return {t: v / norm for t, v in vec.items()}

    def retrieve(self, query: str, k: int = 3, min_score: float = 0.02) -> list[GuidelineSnippet]:
        qvec = self._vectorize(tokenize(query), is_query=True)
        if not qvec:
            return []

        scored: list[tuple[float, int]] = []
        for i, dvec in enumerate(self._doc_vectors):
            if len(qvec) < len(dvec):
                score = sum(w * dvec.get(t, 0.0) for t, w in qvec.items())
            else:
                score = sum(w * qvec.get(t, 0.0) for t, w in dvec.items())
            if score >= min_score:
                scored.append((score, i))

        scored.sort(key=lambda x: x[0], reverse=True)
        results = []
        for score, i in scored[:k]:
            d = self.docs[i]
            results.append(
                GuidelineSnippet(
                    guideline_id=d.get("guideline_id", "unknown"),
                    text=d["text"],
                    evidence_level=d.get("evidence_level"),
                    recommendation_grade=d.get("recommendation_grade"),
                    score=round(score, 4),
                )
            )
        return results


@lru_cache(maxsize=1)
def get_default_store() -> GuidelineStore:
    return GuidelineStore(config.GUIDELINES_PATH)
