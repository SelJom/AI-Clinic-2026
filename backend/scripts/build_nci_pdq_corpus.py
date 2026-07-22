"""Builds a supportive-care guideline corpus from NCI PDQ (cancer.gov) health
professional summaries, replacing the placeholder ESMO early-breast-cancer
*staging* corpus with content that actually matches what the coach cites:
fatigue, sleep, and cardiopulmonary symptom management.

Why NCI PDQ specifically:
  - Topically right: rules.py's guideline_query strings ask for fatigue
    management, sleep/supportive care, and cardiac-symptom monitoring - PDQ's
    Fatigue, Sleep Disorders, and Cardiopulmonary Syndromes summaries cover
    exactly that, unlike the old corpus (breast-cancer screening/staging
    criteria extracted from a copyrighted ESMO journal PDF).
  - Licensing is actually clean: NCI content is a U.S. government work and is
    public domain / free of copyright (see cancer.gov/policies/copyright-reuse)
    - the ESMO PDF was never ours to redistribute in the first place.
  - Freely and directly fetchable as plain HTML, no login or PDF wrangling.

Uses only the standard library (urllib + html.parser), consistent with the
rest of this backend's dependency-free design (see guidelines.py).

Usage:
    python build_nci_pdq_corpus.py ../../nci_pdq_supportive_care_recommendations_clean.jsonl
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from html.parser import HTMLParser

PAGES = [
    {
        "guideline_id": "nci_pdq_fatigue_2024",
        "url": "https://www.cancer.gov/about-cancer/treatment/side-effects/fatigue/fatigue-hp-pdq",
        "include_sections": {"Contributing Factors", "Assessment", "Interventions"},
    },
    {
        "guideline_id": "nci_pdq_sleep_disorders_2024",
        "url": "https://www.cancer.gov/about-cancer/treatment/side-effects/sleep-disorders-hp-pdq",
        "include_sections": {"Sleep Disturbances in Cancer Patients", "Assessment", "Management", "Special Considerations"},
    },
    {
        "guideline_id": "nci_pdq_cardiopulmonary_2025",
        "url": "https://www.cancer.gov/about-cancer/treatment/side-effects/cardiopulmonary-hp-pdq",
        "include_sections": {"Dyspnea in Patients With Advanced Cancer", "Chronic Cough"},
    },
]

LEVEL_RE = re.compile(r"\[\s*Level of evidence:\s*([^\]]+?)\s*\]", re.IGNORECASE)
CITATION_RE = re.compile(r"\[\d+(?:\s*,\s*\d+)*\]")
WHITESPACE_RE = re.compile(r"\s+")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z(])")

MIN_SNIPPET_LEN = 40
MAX_SNIPPET_LEN = 350


class PDQSectionParser(HTMLParser):
    """Extracts (section_title, paragraph_text) pairs from a PDQ page's <p>
    tags, skipping the site nav/header/footer/table-of-contents entirely by
    only capturing <p> content inside a `<div class="pdq-sections">`."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tag_stack: list[str] = []
        self.pdq_div_depth: int | None = None
        self.current_h2 = ""
        self.in_h2 = False
        self.in_p = False
        self.p_parts: list[str] = []
        self.paragraphs: list[tuple[str, str]] = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        self.tag_stack.append(tag)
        if tag == "div" and "pdq-sections" in (attrs_dict.get("class") or ""):
            if self.pdq_div_depth is None:
                self.pdq_div_depth = len(self.tag_stack)
        elif tag == "h2":
            self.in_h2 = True
            self.current_h2 = ""
        elif tag == "p" and self.pdq_div_depth is not None:
            self.in_p = True
            self.p_parts = []

    def handle_endtag(self, tag):
        if tag == "h2":
            self.in_h2 = False
        elif tag == "p" and self.in_p:
            text = "".join(self.p_parts)
            self.paragraphs.append((self.current_h2.strip(), text))
            self.in_p = False
        if self.tag_stack and self.tag_stack[-1] == tag:
            self.tag_stack.pop()
        if self.pdq_div_depth is not None and len(self.tag_stack) < self.pdq_div_depth:
            self.pdq_div_depth = None

    def handle_data(self, data):
        if self.in_h2:
            self.current_h2 += data
        elif self.in_p:
            self.p_parts.append(data)


def clean_snippet(raw_text: str) -> tuple[str, str | None]:
    level_match = LEVEL_RE.search(raw_text)
    evidence_level = level_match.group(1).strip() if level_match else None

    text = LEVEL_RE.sub(" ", raw_text)
    text = CITATION_RE.sub(" ", text)
    text = WHITESPACE_RE.sub(" ", text).strip()
    return text, evidence_level


def split_into_snippets(text: str) -> list[str]:
    if len(text) <= MAX_SNIPPET_LEN:
        return [text]
    return [s.strip() for s in SENTENCE_SPLIT_RE.split(text) if s.strip()]


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def build_corpus() -> list[dict]:
    results = []
    for page in PAGES:
        html = fetch(page["url"])
        parser = PDQSectionParser()
        parser.feed(html)

        order = 0
        for section_title, raw_text in parser.paragraphs:
            if section_title not in page["include_sections"]:
                continue
            text, evidence_level = clean_snippet(raw_text)
            for snippet in split_into_snippets(text):
                if len(snippet) < MIN_SNIPPET_LEN:
                    continue
                order += 1
                results.append(
                    {
                        "guideline_id": page["guideline_id"],
                        "source_url": page["url"],
                        "section_type": section_title,
                        "order_in_section": order,
                        "text": snippet,
                        "evidence_level": evidence_level,
                        "recommendation_grade": None,  # PDQ doesn't use ESMO-style A-E grades
                        "tags": [],
                    }
                )
    return results


if __name__ == "__main__":
    corpus = build_corpus()
    out_path = sys.argv[1] if len(sys.argv) > 1 else None
    lines = [json.dumps(row, ensure_ascii=False) for row in corpus]
    if out_path:
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stdout.write("\n".join(lines) + "\n")
    print(f"# {len(corpus)} snippets extracted", file=sys.stderr)
