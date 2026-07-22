"""Builds a dedicated cardio-oncology supplement to the guideline corpus,
closing the gap flagged in the README ("A dedicated cardio-oncology source
for the tachycardia_* rules"): the NCI PDQ Cardiopulmonary Syndromes summary
already in the corpus covers dyspnea/effusions in advanced cancer, not
cardiac-symptom monitoring during active treatment.

Source: Fauler et al., "Cardio-oncology in Austria: cardiotoxicity and
surveillance of anti-cancer therapies" (position paper, Heart Failure
Working Group of the Austrian Society of Cardiology), PMC9065248, licensed
**CC BY 4.0** - free to reuse and adapt with attribution, confirmed on the
article page itself. This is real clinical-society guidance specifically
about cardiotoxicity monitoring (arrhythmia, ECG, home blood pressure,
symptom red flags), unlike the topically-adjacent PDQ content.

Honest limitation carried over into the corpus entries: this paper's
concrete thresholds (LVEF, GLS, biomarkers) are about periodic clinic-visit
surveillance, not continuous wearable-derived resting HR - it improves the
*topic match* for symptom-awareness content, not the specific numeric
`resting_hr > 120` cutoff, which still needs the clinical review already
tracked in README's "Known gaps".

Uses only the standard library (urllib + html.parser), consistent with the
rest of this backend.

Usage:
    python build_cardio_oncology_corpus.py >> ../../nci_pdq_supportive_care_recommendations_clean.jsonl
    (append, not overwrite - this supplements the existing corpus)
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from html.parser import HTMLParser

URL = "https://pmc.ncbi.nlm.nih.gov/articles/PMC9065248/"
GUIDELINE_ID = "austrian_cardio_oncology_2022"

# Sections with actual monitoring/symptom guidance - skips abstract (redundant
# with body), introduction (generic framing), and boilerplate (glossary,
# funding, conflict of interest, footnotes, references).
INCLUDE_SECTION_IDS = {
    "Sec2", "Sec6", "Sec8", "Sec10", "Sec13", "Sec15",
    "Sec16", "Sec18", "Sec20", "Sec22", "Sec23", "Sec27", "Sec30",
}

CITATION_RE = re.compile(r"\[[\d,\s‐-―-]+\]")
WHITESPACE_RE = re.compile(r"\s+")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z(])")
MIN_SNIPPET_LEN = 40
MAX_SNIPPET_LEN = 350


class CardioOncologyParser(HTMLParser):
    """Captures <p> text only when the innermost currently-open <section>
    id is in INCLUDE_SECTION_IDS - this naturally skips nested table boxes
    (PMC renders tables as nested <section class="tw xbox ..."> elements)
    since their id shadows the parent section's id on the stack."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.section_stack: list[str | None] = []
        self.in_p = False
        self.p_parts: list[str] = []
        self.paragraphs: list[tuple[str, str]] = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if tag == "section":
            self.section_stack.append(attrs_dict.get("id"))
        elif tag == "p" and self.section_stack and self.section_stack[-1] in INCLUDE_SECTION_IDS:
            self.in_p = True
            self.p_parts = []

    def handle_endtag(self, tag):
        if tag == "p" and self.in_p:
            section_id = self.section_stack[-1] if self.section_stack else ""
            self.paragraphs.append((section_id, "".join(self.p_parts)))
            self.in_p = False
        elif tag == "section" and self.section_stack:
            self.section_stack.pop()

    def handle_data(self, data):
        if self.in_p:
            self.p_parts.append(data)


def clean(text: str) -> str:
    text = CITATION_RE.sub(" ", text)
    return WHITESPACE_RE.sub(" ", text).strip()


def split_into_snippets(text: str) -> list[str]:
    if len(text) <= MAX_SNIPPET_LEN:
        return [text]
    return [s.strip() for s in SENTENCE_SPLIT_RE.split(text) if s.strip()]


def build_corpus() -> list[dict]:
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        html = resp.read().decode("utf-8")

    parser = CardioOncologyParser()
    parser.feed(html)

    results = []
    order = 0
    for section_id, raw_text in parser.paragraphs:
        text = clean(raw_text)
        for snippet in split_into_snippets(text):
            if len(snippet) < MIN_SNIPPET_LEN:
                continue
            order += 1
            results.append(
                {
                    "guideline_id": GUIDELINE_ID,
                    "source_url": URL,
                    "section_type": section_id,
                    "order_in_section": order,
                    "text": snippet,
                    "evidence_level": None,
                    "recommendation_grade": None,
                    "tags": ["cardio-oncology"],
                }
            )
    return results


if __name__ == "__main__":
    corpus = build_corpus()
    lines = [json.dumps(row, ensure_ascii=False) for row in corpus]
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdout.write("\n".join(lines) + "\n")
    print(f"# {len(corpus)} snippets extracted", file=sys.stderr)
