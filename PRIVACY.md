# Privacy & data handling

This document is the "ethics/privacy pass" called out as a gap in
[README.md](README.md). It describes what actually exists in the code today,
what's still missing, and why - it is **not** a legal opinion and does not
substitute for review by a lawyer or a compliance professional before any
real patient's data touches this system. Nothing in this repo has ever
processed real patient data; the honesty here is about a prototype's design,
not a compliance certification.

## What data exists, and where it lives

The backend stores four kinds of data, all in one local SQLite file
(`backend/data/local.db` by default, see `config.py`'s `DB_PATH`):

| Table | Contents |
|---|---|
| `samples` | Raw wearable readings (HR, sleep minutes, steps, fatigue score) |
| `daily_features` | Per-day aggregates and personal-baseline z-scores |
| `risk_assessments` | Which rules fired, on which day, at what risk level |
| `chat_history` | Coach conversation turns |

There is no cloud sync, no analytics/telemetry, no third-party SDK call, and
no account system. The FastAPI bridge (`api.py`) only binds `127.0.0.1` and
its CORS policy only allows loopback origins (`api.py:24-29`) - nothing
reaches this server from outside the device it runs on. The only outbound
network call anywhere in the backend is to a local Ollama daemon, and only
if one is already running on `127.0.0.1:11434` (`llm_backends.py`); if it
isn't, everything falls back to a template responder and no network call
happens at all.

## Rights this system can technically honor today

Two of the concrete rights a privacy framework like GDPR expects - access
and erasure - now have real implementations, not just a policy promise:

- **Right to access / data portability**: `GET /patient/{id}/export` (API)
  or `python -m health_coach.cli export-patient <id>` (CLI) - dumps every
  row stored for that patient as JSON. See `storage.export_patient_data()`.
- **Right to erasure**: `DELETE /patient/{id}` (API) or
  `python -m health_coach.cli delete-patient <id>` (CLI, prompts for
  confirmation unless `--yes`) - permanently deletes every row for that
  patient across all four tables. See `storage.delete_patient_data()`.
  This is irreversible by design: there is no soft-delete, because there is
  also no backup anywhere to recover from - the same "everything stays
  local" property that protects privacy also means deletion is final.
- **Explainability**: every recommendation carries its triggering rule
  (`rule_trace`) and guideline citations (`Recommendation.citations`), and
  `CoachAgent.explain_last_recommendation()` / `GET /chat/{id}/explain`
  answer "why did you say that" from the same structured data the rule
  engine already computed - not a post-hoc LLM rationalization.

## What's explicitly *not* done yet

Being honest about gaps is more useful than a reassuring document that
oversells them:

1. **No consent flow.** The app doesn't ask permission before reading health
   data or show a privacy notice before first use. For a real deployment,
   informed consent needs to be obtained *before* the first `/ingest` call,
   not assumed.
2. **No encryption at rest.** `local.db` is a plain SQLite file - anyone
   with filesystem access to the device can read it. Python's stdlib
   `sqlite3` module doesn't support encryption; adding it means a real
   dependency change (e.g. SQLCipher via `pysqlcipher3`), which is a
   deliberate choice to defer rather than bolt on hastily, since it changes
   the storage layer's dependency footprint (currently zero) for every user
   even in pure-demo mode.
3. **No retention policy.** Data persists indefinitely until someone calls
   the new delete endpoint/CLI command manually. There's no automatic
   expiry (e.g. "purge raw samples after 90 days"), and no policy decision
   has been made about what retention period would even be appropriate -
   that's a product/clinical decision, not something to default silently.
4. **No audit log.** There's no record of *who* accessed or exported a
   patient's data, only that the data exists. Irrelevant for a single-user
   local prototype; a real requirement the moment a clinician-facing or
   multi-user mode exists.
5. **HIPAA applicability hasn't been assessed.** Whether this system would
   be a "covered entity" or "business associate" under HIPAA depends
   entirely on deployment context (is it operated by/for a healthcare
   provider?) - that's a legal determination, not a code change, and it's
   out of scope for me to make.
6. **GDPR lawful basis and Article 30 records** (a register of processing
   activities) aren't documented anywhere, because there's no real
   processing of real personal data yet to document.

## If this were to handle real patient data next

In priority order, given what exists now: (1) build the consent flow before
any device ever calls `/ingest`, (2) get a real answer on HIPAA applicability
for the intended deployment before assuming either way, (3) decide and
implement a retention policy, (4) add encryption at rest, (5) add audit
logging once there's any scenario beyond a single local user. None of these
are exotic engineering problems - they're deliberately sequenced *after*
legal/clinical input, not before it, because guessing at compliance
requirements and shipping code against the guess is worse than leaving the
gap explicit.
