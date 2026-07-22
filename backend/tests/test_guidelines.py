from health_coach.guidelines import get_default_store


def test_corpus_loads_and_retrieves_relevant_snippets():
    store = get_default_store()
    assert len(store.docs) > 0

    results = store.retrieve("fatigue management exercise intervention", k=3)
    assert len(results) > 0
    assert all(r.score > 0 for r in results)
    assert results == sorted(results, key=lambda r: r.score, reverse=True)


def test_irrelevant_query_returns_few_or_no_results():
    store = get_default_store()
    results = store.retrieve("quantum computing spacecraft engine", k=3)
    assert len(results) <= 1
