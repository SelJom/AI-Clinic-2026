import json
from unittest.mock import patch

from health_coach.llm_backends import (
    CoachContext,
    OllamaBackend,
    TemplateBackend,
    ground_citations,
    ground_reply,
)


def _ctx(**overrides) -> CoachContext:
    base = dict(
        patient_id="p1",
        risk_level="normal",
        recommendation_summaries=[],
        guideline_snippets=[],
        escalate=False,
        recent_chat=[],
    )
    base.update(overrides)
    return CoachContext(**base)


def test_template_backend_flags_escalation():
    reply = TemplateBackend().generate("hi", _ctx(escalate=True))
    assert "reach out to your care team" in reply


def test_template_backend_lists_recommendations():
    reply = TemplateBackend().generate(
        "hi", _ctx(recommendation_summaries=["Your sleep was below your baseline."])
    )
    assert "Your sleep was below your baseline." in reply


def test_template_backend_reports_no_findings_when_nothing_flagged():
    reply = TemplateBackend().generate("hi", _ctx())
    assert "nothing stands out today" in reply.lower()


def test_template_backend_answers_why_with_guideline_context():
    reply = TemplateBackend().generate(
        "why do you say that?",
        _ctx(guideline_snippets=["Encourage regular sleep habits to manage fatigue."]),
    )
    assert "baseline" in reply.lower()
    assert "Encourage regular sleep habits to manage fatigue." in reply


# --- ground_reply: unconditional post-generation safety net -----------------
# Regression coverage for the "we can't prompt-engineer every phrasing"
# problem: this doesn't depend on how the question was asked, only on
# whether the model's stated number actually appears in the real data.

def test_ground_reply_strips_ungrounded_sleep_figure():
    ctx = _ctx(recent_trend=["2026-08-25: resting HR 71 bpm, sleep 5.1h, steps 3200"])
    reply = ground_reply("Your average sleep was 6.0h last week.", ctx)
    assert "6.0h" not in reply
    assert "a specific figure I don't have handy" in reply


def test_ground_reply_keeps_grounded_figures_from_trend():
    ctx = _ctx(recent_trend=["2026-08-25: resting HR 71 bpm, sleep 5.1h, steps 3200"])
    reply = ground_reply("Your lowest sleep was 5.1h, with a heart rate of 71 bpm.", ctx)
    assert "5.1h" in reply
    assert "71 bpm" in reply
    assert "don't have handy" not in reply


def test_ground_reply_catches_unit_before_number_phrasing():
    """Regression test for a real live failure: the model said "steps were
    8500" (real value 8247) - a number-then-unit-only pattern missed this
    because the unit came first."""
    ctx = _ctx(recent_trend=["2026-08-30: resting HR 69 bpm, sleep 8.0h, steps 8247"])
    reply = ground_reply("Your steps were 8500 today.", ctx)
    assert "8500" not in reply
    assert "a specific figure I don't have handy" in reply

    # And the correctly-grounded reversed phrasing must survive untouched.
    reply2 = ground_reply("Your steps were 8247 today.", ctx)
    assert "8247" in reply2


def test_ground_reply_keeps_grounded_figures_from_precomputed_stats():
    ctx = _ctx(trend_stats=["sleep over 3 days: average 6.4h, lowest 5.1h on 2026-08-25, highest 7.2h on 2026-08-24"])
    reply = ground_reply("On average you slept 6.4h.", ctx)
    assert "6.4h" in reply
    assert "don't have handy" not in reply


def test_ground_reply_keeps_figures_sourced_from_guideline_citations():
    ctx = _ctx(guideline_snippets=["Patients should aim for at least 100 bpm during light activity."])
    reply = ground_reply("Guidelines suggest aiming for 100 bpm during light activity.", ctx)
    assert "100 bpm" in reply
    assert "don't have handy" not in reply


def test_ground_reply_ignores_numbers_without_a_matching_unit():
    ctx = _ctx()
    reply = ground_reply("Try to keep replies to 3-5 sentences and check in again in 2 days.", ctx)
    assert reply == "Try to keep replies to 3-5 sentences and check in again in 2 days."


def test_ground_reply_does_not_mangle_ordinary_words_starting_with_h():
    """Regression test for a real live failure: the reversed "unit-before-
    number" pattern added for "steps were 8500" had no word boundary after
    the unit token, so "h" (the optional "ours?" suffix left unmatched)
    matched the leading letter of ordinary words like "helpful", then
    walked forward looking for any digit - which a markdown numbered list
    always supplies. The digit was never grounded, so the whole span,
    including unrelated prose, got deleted: "strategies that can be
    helpful:\\n\\n1. **Prioritize Rest:**" became "strategies that can be a
    specific figure I don't have handy. **Prioritize Rest:**"."""
    ctx = _ctx()
    reply = ground_reply(
        "Here are a few strategies that can be helpful:\n\n1. **Prioritize Rest:** get enough sleep.\n"
        "2. **Balanced Diet:** eat well.",
        ctx,
    )
    assert "a specific figure I don't have handy" not in reply
    assert "helpful" in reply
    assert "1. **Prioritize Rest:**" in reply


def test_ground_reply_still_catches_reversed_phrasing_with_word_boundary_fix():
    """The word-boundary fix must not reintroduce the original bug it was
    layered on top of - "steps were 8500" (real value 8247) must still be
    caught."""
    ctx = _ctx(recent_trend=["2026-08-30: resting HR 69 bpm, sleep 8.0h, steps 8247"])
    reply = ground_reply("Your steps were 8500 today.", ctx)
    assert "8500" not in reply
    assert "a specific figure I don't have handy" in reply


# --- ground_reply: hedged approximations get a looser tolerance ------------
# Regression coverage for a real failure hit live during demo recording:
# "you've already racked up over 8,000 steps" (real value 8247) was stripped
# to "...racked up over a specific figure I don't have handy" mid-sentence -
# a hedged, honestly-approximate figure was being held to the same
# exact-match bar as a bare precise-looking claim.

def test_ground_reply_keeps_hedged_approximate_figure():
    ctx = _ctx(recent_trend=["2026-08-31: resting HR 69 bpm, sleep 7.8h, steps 8247"])
    reply = ground_reply("You've already racked up over 8,000 steps today.", ctx)
    assert "over 8,000 steps" in reply
    assert "don't have handy" not in reply


def test_ground_reply_keeps_hedged_approximate_figure_various_hedge_words():
    ctx = _ctx(recent_trend=["2026-08-31: resting HR 69 bpm, sleep 7.8h, steps 8247"])
    for phrase in ["nearly 8,000 steps", "about 8,200 steps", "close to 8,000 steps"]:
        reply = ground_reply(f"You've done {phrase} today.", ctx)
        assert phrase in reply, f"{phrase!r} should have survived grounding"


def test_ground_reply_hedge_word_is_not_a_blanket_bypass():
    """A hedge word loosens the tolerance, but not infinitely - a wildly
    wrong figure must still be caught even when hedged."""
    ctx = _ctx(recent_trend=["2026-08-31: resting HR 69 bpm, sleep 7.8h, steps 8247"])
    reply = ground_reply("You've done nearly 20,000 steps today.", ctx)
    assert "20,000" not in reply
    assert "a specific figure I don't have handy" in reply


def test_ground_reply_bare_precise_figure_still_uses_strict_tolerance():
    """Without a hedge word, a precise-looking figure must still be held to
    the tight tolerance even if it's in the same ballpark as the real value -
    this is the exact shape of the original live hallucination
    (test_ground_reply_catches_unit_before_number_phrasing) and must not
    regress just because hedged phrasing is now more lenient."""
    ctx = _ctx(recent_trend=["2026-08-31: resting HR 69 bpm, sleep 7.8h, steps 8247"])
    reply = ground_reply("Your steps were 8500 today.", ctx)
    assert "8500" not in reply
    assert "a specific figure I don't have handy" in reply


def test_ollama_backend_grounds_reply_before_returning(monkeypatch):
    fabricated = "Your average sleep was 6.0h and heart rate 200 bpm."
    fake_response = json.dumps({"response": fabricated}).encode("utf-8")

    class FakeResp:
        def read(self):
            return fake_response

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    with patch("health_coach.llm_backends.urllib.request.urlopen", return_value=FakeResp()):
        ctx = _ctx(recent_trend=["2026-08-25: resting HR 71 bpm, sleep 5.1h, steps 3200"])
        reply = OllamaBackend().generate("what's my average sleep and heart rate?", ctx)

    assert "6.0h" not in reply
    assert "200 bpm" not in reply
    assert reply.count("a specific figure I don't have handy") == 2


# --- ground_citations: strips fabricated named-source attributions ----------
# Regression coverage for a real failure: asked about medication interactions,
# the model attributed its answer to the "National Comprehensive Cancer
# Network (NCCN)" - a real organization never present in guideline_snippets.

def test_ground_citations_strips_fabricated_organization():
    ctx = _ctx(guideline_snippets=["Discuss any medication with your care team before use."])
    reply = ground_citations(
        "According to the National Comprehensive Cancer Network (NCCN), consult your care team.", ctx
    )
    assert "NCCN" not in reply
    assert "National Comprehensive Cancer Network" not in reply
    assert "a general clinical source" in reply


def test_ground_citations_keeps_organization_actually_in_guidelines():
    ctx = _ctx(guideline_snippets=["Per the American Heart Association (AHA), monitor resting HR."])
    reply = ground_citations("The American Heart Association (AHA) recommends monitoring your resting HR.", ctx)
    assert "American Heart Association (AHA)" in reply


def test_ground_citations_ignores_non_parenthetical_self_references():
    ctx = _ctx()
    reply = "According to the Precomputed trend statistics, your average sleep is 6.9 hours."
    assert ground_citations(reply, ctx) == reply


def test_ground_citations_strips_bare_ungrounded_authority_acronym():
    ctx = _ctx(guideline_snippets=["Discuss any medication with your care team before use."])
    reply = ground_citations("The FDA has not approved ibuprofen for use during cancer treatment.", ctx)
    assert "FDA" not in reply
    assert "a general clinical source" in reply


def test_ground_citations_keeps_bare_acronym_actually_in_guidelines():
    ctx = _ctx(guideline_snippets=["Per WHO guidance, monitor symptoms closely during treatment."])
    reply = ground_citations("WHO guidance recommends monitoring your symptoms.", ctx)
    assert "WHO" in reply
