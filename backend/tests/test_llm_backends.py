from health_coach.llm_backends import CoachContext, TemplateBackend


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
