"""Converts rag.md (a general, non-oncology-specific evidence-based health
reference the user assembled - calories, macros, activity/steps, sleep, BMI,
blood pressure, glucose, lipids, alcohol/caffeine limits, supplements, etc.)
into the same JSONL schema the rest of the guideline corpus uses, so it flows
through the identical GuidelineStore retrieval + ground_reply/ground_citations
pipeline as every other cited source in this app.

Real gap this closes: the existing corpus (NCI PDQ cancer-supportive-care
extracts) has zero mentions of "steps", macros, or most everyday nutrition/
activity questions - confirmed live, a patient asking "how many steps should
I aim for" had nothing for retrieval to ground an answer in at all.

Honesty note, deliberately not glossed over: unlike the NCI PDQ corpus (a raw
scrape of one cited institutional page per guideline_id, each with a real
source_url), rag.md is a *consolidated* reference the user compiled from
several major guideline bodies (USDA/HHS, WHO, AHA, CDC, National Academies,
NIH ODS, EFSA...), with per-figure citation markers like "[8]" that don't
resolve to a bibliography in this file. So source_url is honestly left null
here rather than inventing a single page this content didn't come from -
each entry's guideline_id and section title are what's traceable, not a URL.

Chunking: one chunk per markdown subsection (### headers) where they exist,
else one chunk per top-level section (##) - matches the file's own "one
section = one chunk" guidance while staying granular enough for the TF-IDF
retriever to actually distinguish e.g. "protein" from "fiber" instead of
diluting both into one giant "macronutrients" blob. Section 15 ("How to Use
This in RAG") is meta-instruction about building the RAG itself, not health
content - excluded, it would make no sense if ever surfaced to a patient.

Usage:
    python build_general_health_reference_corpus.py ../../rag.md > ../../general_health_reference.jsonl
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

_SKIP_SECTION_TITLES = {"how to use this in rag"}

_H2_RE = re.compile(r"^##\s+(?:\d+\.\s*)?(.+?)\s*$", re.MULTILINE)
_H3_RE = re.compile(r"^###\s+(?:\d+\.\d+\s*)?(.+?)\s*$", re.MULTILINE)


def _slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")
    return slug


def _clean_body(text: str) -> str:
    # Drop a leading "**Source(s):** ..." attribution line into the body as
    # plain text (still useful context for the model) but strip the
    # bracketed numeric citation markers ("[8]", "[33]", ...) throughout -
    # they don't resolve to anything in this file and would just look like
    # broken citations if echoed back to a patient.
    text = re.sub(r"\[\d+(?:,\s*\d+)*\]", "", text)
    text = re.sub(r"^\s*---\s*$", "", text, flags=re.MULTILINE)  # markdown hr between sections
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def build_entries(md_text: str) -> list[dict]:
    entries: list[dict] = []

    h2_matches = list(_H2_RE.finditer(md_text))
    for i, h2 in enumerate(h2_matches):
        section_title = h2.group(1).strip()
        if section_title.lower() in _SKIP_SECTION_TITLES:
            continue

        section_start = h2.end()
        section_end = h2_matches[i + 1].start() if i + 1 < len(h2_matches) else len(md_text)
        section_body = md_text[section_start:section_end]
        section_slug = _slugify(section_title)

        h3_matches = list(_H3_RE.finditer(section_body))
        if not h3_matches:
            body = _clean_body(section_body)
            if len(body) < 20:
                continue
            entries.append(
                {
                    "guideline_id": f"general_health_reference_{section_slug}",
                    "source_url": None,
                    "section_type": section_title,
                    "order_in_section": 1,
                    "text": f"{section_title}\n\n{body}",
                    "evidence_level": None,
                    "recommendation_grade": None,
                    "tags": [],
                }
            )
            continue

        for j, h3 in enumerate(h3_matches):
            sub_title = h3.group(1).strip()
            sub_start = h3.end()
            sub_end = h3_matches[j + 1].start() if j + 1 < len(h3_matches) else len(section_body)
            body = _clean_body(section_body[sub_start:sub_end])
            if len(body) < 20:
                continue
            entries.append(
                {
                    "guideline_id": f"general_health_reference_{section_slug}_{_slugify(sub_title)}",
                    "source_url": None,
                    "section_type": f"{section_title} - {sub_title}",
                    "order_in_section": j + 1,
                    "text": f"{section_title} - {sub_title}\n\n{body}",
                    "evidence_level": None,
                    "recommendation_grade": None,
                    "tags": [],
                }
            )

    return entries


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: python {Path(__file__).name} <rag.md path>")

    md_text = Path(sys.argv[1]).read_text(encoding="utf-8")
    entries = build_entries(md_text)
    for entry in entries:
        sys.stdout.write(json.dumps(entry) + "\n")
    print(f"Wrote {len(entries)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
