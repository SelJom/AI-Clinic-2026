import pdfplumber
import re
import json
from pathlib import Path

PDF_PATH = "/Users/clementfrerebeau/Downloads/PIIS0923753423051049.pdf"   # ton guideline ESMO
GUIDELINE_ID = "esmo_early_breast_cancer_2024"

# Regex pour trouver les grades de recommandation [II, A] etc.
GRADE_RE = re.compile(r"\[([IVX]+)\s*,\s*([A-E])\]")

def extract_text_from_pdf(path):
    pages_text = []
    with pdfplumber.open(path) as pdf:
        for i, page in enumerate(pdf.pages):
            text = page.extract_text() or ""
            pages_text.append(text)
    # on joint les pages avec un séparateur
    return "\n\n===PAGE_BREAK===\n\n".join(pages_text)

def split_sections_on_recommendations(text):
    """
    Retourne une liste de blocs (section_title, bloc_texte)
    à partir des en-têtes 'Recommendations'.
    """
    sections = []
    pattern = re.compile(r"(?m)^(Recommendations)\s*$")
    matches = list(pattern.finditer(text))

    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        block = text[start:end].strip()
        sections.append(("Recommendations", block))
    return sections

def extract_recommendation_lines(block):
    """
    Les recommandations sont souvent sous forme de lignes
    qui commencent par un espace ou une puce.
    On simplifie : on prend chaque ligne non vide qui
    commence par un espace / tiret / puce.
    """
    recos = []
    for line in block.splitlines():
        clean = line.strip()
        if not clean:
            continue
        # Ignore obvious headings
        if clean.isupper() and len(clean.split()) < 6:
            continue
        # On garde la ligne
        recos.append(clean)
    return recos

def parse_grade(text):
    """
    Extrait [I, A] -> (I, A) sinon (None, None)
    """
    m = GRADE_RE.search(text)
    if not m:
        return None, None
    return m.group(1), m.group(2)

def build_json_objects(pdf_path):
    raw_text = extract_text_from_pdf(pdf_path)
    sections = split_sections_on_recommendations(raw_text)

    results = []
    for sec_idx, (sec_title, block) in enumerate(sections):
        reco_lines = extract_recommendation_lines(block)
        for order, line in enumerate(reco_lines, start=1):
            level, grade = parse_grade(line)
            obj = {
                "guideline_id": GUIDELINE_ID,
                "source_file": Path(pdf_path).name,
                "section_type": sec_title,
                "section_index": sec_idx,
                "order_in_section": order,
                "text": line,
                "evidence_level": level,  # ex: "I", "II", "III", "V"
                "recommendation_grade": grade,  # ex: "A", "B", "D"
                # champ pour filtrer par type plus tard
                "tags": []
            }
            results.append(obj)
    return results

if __name__ == "__main__":
    recos = build_json_objects(PDF_PATH)

    # Sauvegarde en JSONL (une reco par ligne)
    out_path = "esmo_early_breast_cancer_recommendations.jsonl"
    with open(out_path, "w", encoding="utf-8") as f:
        for r in recos:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"✅ {len(recos)} recommandations extraites dans {out_path}")