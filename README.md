# Personalized Health Coach Agent (Critical Disease Patients)

Local-first health coach for cancer patients: a phone app reads wearable data,
a local Python service turns it into personalized risk signals and
guideline-grounded coaching, entirely on-device / on-loopback. No cloud
dependency, no deployment - everything runs on the developer's machine today.

Original project brief: see [`docs/brief.md`](docs/brief.md).

## Quickstart

```bash
# 1. Backend - local HTTP bridge (binds 127.0.0.1:8765 only)
cd backend
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt      # macOS/Linux: .venv/bin/pip
.venv/Scripts/python -m health_coach.cli serve      # macOS/Linux: .venv/bin/python

# 2. Flutter app - in a second terminal
cd health_coaching_app
flutter pub get
flutter run
```

Android emulator only: before step 2, run `adb reverse tcp:8765 tcp:8765` so
the emulator's `127.0.0.1` reaches your machine (desktop builds and the iOS
simulator need no setup - see "Reaching 127.0.0.1 from the app" below for
physical devices).

That's it - the app now shows a real, guideline-grounded risk assessment and
chat, computed from `HealthService`'s current numbers. On Android/iOS,
`HealthService` now attempts a real Health Connect/HealthKit read and only
falls back to simulated numbers if permission is denied or the platform
doesn't support it (desktop always falls back - there's no Health Connect/
HealthKit equivalent there); either way, everything downstream - baselines,
anomaly scoring, rule engine, guideline retrieval, chat, escalation - is real.

To explore the backend on its own without the app, see "Running the backend"
below for `cli demo`, which seeds synthetic history and opens a local chat
directly in the terminal.

## Current state (honest snapshot)

| Piece | Status |
|---|---|
| Flutter app shell (`health_coaching_app/`) | UI built; steps/HR/sleep come from `HealthService`, which now attempts a **real** Health Connect/HealthKit read on Android/iOS and falls back to simulated data only when permission is denied or unsupported (desktop) |
| `HealthService` (Health Connect/HealthKit) | **Rewired.** Fixed a real bug (the `health` v13 package removed its singleton and requires `configure()` - neither was happening), added the Android manifest permissions/`activity-alias`/`FlutterFragmentActivity` Health Connect actually needs, and made `_shouldUseSimulatedData()` check real permission status instead of hardcoding `true` |
| App ↔ backend bridge | Working. `TodayScreen` posts today's metrics to `/ingest` and renders the backend's real risk assessment; `AIChatScreen` calls `/chat` for real guideline-grounded replies. See `lib/services/backend_service.dart` |
| AI chat screen | No longer canned - talks to the local FastAPI backend's `/chat`, with an honest fallback message if the backend isn't running |
| Guideline corpus | NCI PDQ supportive-care summaries (fatigue, sleep disorders, cardiopulmonary symptoms) plus, **new**, a dedicated CC BY-licensed cardio-oncology position paper specifically for the `tachycardia_*` rules - 914 snippets total. Public-domain/openly-licensed content throughout, replacing the old ESMO early-breast-cancer *staging* corpus (off-topic and copyrighted) |
| Escalation | `/escalation/{patient_id}` produces an actual clinician-facing summary - measurements vs. baseline, flagged rules with guideline citations, recent trend. **New**: the Flutter app now has a real `EscalationScreen` that shows it and a "share with your care team" button (native share sheet), closing the delivery gap that existed before |
| Data rights | **New.** `DELETE /patient/{id}` and `GET /patient/{id}/export` (plus `cli.py delete-patient`/`export-patient`) actually implement right-to-erasure and right-to-access, not just a policy promise. See [`PRIVACY.md`](PRIVACY.md) for what's covered and what still isn't (consent flow, encryption at rest, retention policy, audit log) |
| Python backend (`backend/`) | Working. Local pipeline: baselines → anomaly rules → guideline retrieval → coaching replies. The Flutter app now calls it directly over loopback |
| Tests | Backend: 65 passing (`pytest -q` from `backend/`), up from 17. Flutter: 8 passing (`flutter test` from `health_coaching_app/`) covering the responsive shell and the trend screen, both added this round after the previous suite (one file, stale UI text, never actually run) was discovered broken the first time anyone ran `flutter test` |
| Real AI verification | **Confirmed live, not assumed, repeatedly.** Ollama installed and running with `llama3.2` (`config.py`'s default) let the LLM layer be exercised directly rather than unit-tested against a fake. A 20-question live battery surfaced and fixed real failures beyond the original fabrication bug - see "Live-testing round 2" below |
| Trend/history screen | **New.** `TrendScreen` + `GET /trend/{patient_id}` - resting HR/sleep/steps charted over time (via `fl_chart`), with the patient's own rolling baseline as a reference line. Previously this data only ever surfaced inside chat answers, never visually. Reachable from the chart icon in `TodayScreen`'s app bar |
| Android build | **New.** Full Android toolchain (JDK 17, Android SDK cmdline-tools, platform 36, build-tools 28.0.3) set up and verified with a real `flutter build apk --debug` |

Nothing here has touched a real patient's data. The synthetic generator in
`backend/health_coach/ingestion.py` exists specifically so the pipeline can be
built and tested before any real wearable is connected. Its noise parameters
were first calibrated against [MMASH](https://physionet.org/content/mmash/1.0.0/)
(PhysioNet, 22 healthy adults, a single ~24-48h session each), then
**superseded** by [LifeSnaps](https://doi.org/10.5281/zenodo.6826682)
(Zenodo, open access, 71 adults, real Fitbit Sense data over a median of 88
days each) - see
[`backend/scripts/calibrate_from_lifesnaps.py`](backend/scripts/calibrate_from_lifesnaps.py)
to reproduce. LifeSnaps matters because it has *repeated* days per person, so
it's the first real source for `steps_noise` (MMASH's single-session design
structurally couldn't measure day-to-day step variability) and a better one
for `hr_noise`/`sleep_noise` than MMASH's few-partial-day proxy. Both cohorts
are general/healthy adults, not oncology patients, so - same caveat as
before - only the *noise* parameters come from real data; the *baseline
levels* stay clinically-informed placeholders. See the docstring on
`PatientProfile` in `ingestion.py` for exact numbers and reasoning.
[DREAMT](https://physionet.org/content/dreamt/2.2.0/) (wearable sleep-staging)
would sharpen the sleep-signal side further but is PhysioNet **Restricted
Access** - it requires your own credentialed PhysioNet account and a signed
Data Use Agreement, which only you can complete.

### Guideline corpus provenance

`nci_pdq_supportive_care_recommendations_clean.jsonl` (722 snippets) is built
by [`backend/scripts/build_nci_pdq_corpus.py`](backend/scripts/build_nci_pdq_corpus.py)
from three NCI PDQ health-professional summaries - Fatigue, Sleep Disorders,
and Cardiopulmonary Syndromes - fetched directly from cancer.gov (stdlib
`urllib` + `html.parser`, no extra dependencies, no login). NCI content is a
U.S. government work and explicitly free of copyright and reusable (see
[cancer.gov's reuse policy](https://www.cancer.gov/policies/copyright-reuse)),
unlike the ESMO journal PDF the old corpus was scraped from.

Retrieval quality against `rules.py`'s actual queries is good for fatigue and
sleep (e.g. `"fatigue management supportive care quality of life"` and
`"sleep fatigue quality of life supportive care"` both return directly
relevant supportive-care snippets). Cardiac monitoring was initially
**weaker** - the Cardiopulmonary Syndromes PDQ covers dyspnea/effusions/cough
in advanced cancer, not resting-heart-rate/tachycardia monitoring - so a
dedicated source was added:
[`build_cardio_oncology_corpus.py`](backend/scripts/build_cardio_oncology_corpus.py)
extracts 192 snippets from Fauler et al.'s "Cardio-oncology in Austria:
cardiotoxicity and surveillance of anti-cancer therapies" (Heart Failure
Working Group of the Austrian Society of Cardiology, **CC BY 4.0**, confirmed
on the article page), which directly discusses arrhythmia, ECG monitoring,
and cardiac symptom red flags during cancer treatment. Querying
`"cardiac monitoring symptoms treatment toxicity"` now surfaces this source
first instead of tangential fatigue content. Honest limit carried over: this
paper's concrete thresholds (LVEF, biomarkers, clinic-visit intervals) still
don't map to a continuous wearable-derived resting-HR number - it improves
the *topic match* for symptom-awareness content, not a numeric validation of
the `resting_hr > 120` cutoff, which still needs the clinical review in
"Known gaps" below.

The old ESMO extraction script (`health_coaching_app/test.py`) and
`esmo_early_breast_cancer_recommendations_clean.jsonl` are left in the repo
for reference but are no longer the default - set
`HEALTH_COACH_GUIDELINES_PATH` to point back at it if needed.

### Tachycardia threshold sanity check

The `resting_hr > 120` cutoff in `tachycardia_severe` (`rules.py`) was
sanity-checked against the **MIT-BIH Arrhythmia Database** (PhysioNet, open
access, ~110,000 cardiologist-annotated beats) - see
[`backend/scripts/analyze_mitbih_tachycardia.py`](backend/scripts/analyze_mitbih_tachycardia.py).
Real normal-sinus-rhythm beats topped out around the 90th percentile at ~107
bpm instantaneous, so 120 has genuine margin above ordinary variation - but
real ventricular-tachycardia episodes in that data ranged as low as ~90 bpm
at the 10th percentile, meaning a single "> 120" cutoff would miss some
genuine tachyarrhythmias. That data is continuous hospital ECG from
arrhythmia patients, not once-daily wrist-derived resting HR from ambulatory
cancer patients, so this is a plausibility check on the cutoff's magnitude,
not a validation of its clinical sensitivity - the real clinical review in
"Known gaps" below still stands.

### Escalation summaries

Before this, "escalation" meant a chat message telling the *patient* to
contact their care team - there was no artifact the patient could actually
bring to, show, or send a clinician. `escalation.py`'s
`build_escalation_summary()` assembles one from data the pipeline already
computed: today's measurements vs. personal baseline, which rules fired and
their guideline citations, and a recent-days trend. It's exposed at
`GET /escalation/{patient_id}` (returns structured JSON plus a ready-to-share
`text` field) and printed directly in `cli.py demo` whenever a day escalates.
Nothing is sent anywhere - same local-first design as the rest of the
backend; it's the patient's to view, copy, or export themselves. **New:**
`lib/screens/escalation_screen.dart` renders this in the app - measurements,
findings with citations, trend - with a "share with your care team" button
using `share_plus`'s native OS share sheet, reachable from `TodayScreen`'s
"Care Team" button (which was previously an inert, unwired "View Trends"
placeholder).

Still missing: a *proactive* delivery channel (local notification when a day
escalates, rather than the patient having to open the app and tap through).

### Data rights and privacy

`GET /patient/{id}/export` and `DELETE /patient/{id}` (also available as
`cli.py export-patient`/`delete-patient`) implement the two data rights that
are actually testable in code: access/portability (dump everything stored
locally as JSON) and erasure (permanently remove every row for a patient
across all four tables - irreversible by design, since there's also no
backup to recover from). See [`storage.py`](backend/health_coach/storage.py)'s
`export_patient_data()`/`delete_patient_data()`.

**[PRIVACY.md](PRIVACY.md)** is the honest accounting of what this does and
doesn't cover: no consent flow yet, no encryption at rest (`local.db` is a
plain SQLite file), no retention policy (data persists until manually
deleted), no audit log, and no legal determination of GDPR lawful basis or
HIPAA applicability - those need human/legal input this document is
explicit about not being a substitute for.

### HealthService and Health Connect setup

Real device reads needed more than flipping a boolean. Two real problems
were fixed:

1. **A latent bug in `health_service.dart` itself.** The `health` package
   v13 removed its singleton pattern (`Health()` now returns a fresh
   instance every call, not a cached one) and requires `configure()` before
   any use - the previous code called `Health()` fresh in every method and
   never called `configure()` at all. Fixed by keeping one `Health`
   instance for the service's lifetime, configured lazily on first use.
2. **Missing Android manifest wiring.** Health Connect needs specific
   `READ_STEPS`/`READ_RESTING_HEART_RATE`/`READ_SLEEP_IN_BED` permissions, a
   `<queries>` block to detect the Health Connect app, an
   `ACTION_SHOW_PERMISSIONS_RATIONALE` intent filter, a
   `ViewPermissionUsageActivity` activity-alias, and `MainActivity`
   extending `FlutterFragmentActivity` (not `FlutterActivity`) - none of
   which were present. All added to `AndroidManifest.xml` and
   `MainActivity.kt`.

`_shouldUseSimulatedData()` now actually checks platform support and
permission status (requesting permission once on first real use) instead of
unconditionally returning `true`. **I could not test this against a real
device or emulator** - this environment has neither - so treat it as
carefully-reviewed-but-unverified rather than confirmed working; the
`flutter analyze`/`flutter pub get` step in "Running the Flutter app" below
matters more than usual here.

## Repository layout

```
.
├── health_coaching_app/        Flutter app (iOS/Android/desktop)
│   ├── lib/services/health_service.dart   Health Connect/HealthKit reads (real, on Android/iOS)
│   ├── lib/services/backend_service.dart  HTTP client for the local FastAPI bridge
│   ├── lib/screens/today_screen.dart      Daily summary UI, backed by /ingest + /summary
│   ├── lib/screens/ai_chat_screen.dart    Chat UI, backed by /chat
│   ├── lib/screens/escalation_screen.dart Clinician-summary view + share sheet, backed by /escalation
│   ├── android/.../MainActivity.kt        FlutterFragmentActivity (Health Connect requirement)
│   ├── android/.../AndroidManifest.xml    Health Connect permissions/queries/activity-alias
│   └── test.py                            Old ESMO PDF -> JSONL extractor (superseded, kept for reference)
├── backend/                    Local Python service
│   ├── scripts/
│   │   ├── calibrate_from_mmash.py        Superseded first pass at PatientProfile noise params
│   │   ├── calibrate_from_lifesnaps.py    Current source: real longitudinal Fitbit noise params
│   │   ├── build_nci_pdq_corpus.py        Builds the fatigue/sleep/cardiopulmonary corpus from cancer.gov
│   │   ├── build_cardio_oncology_corpus.py Supplements it with a dedicated cardio-oncology source
│   │   └── analyze_mitbih_tachycardia.py  Sanity-checks tachycardia cutoffs against real ECG
│   └── health_coach/
│       ├── models.py, storage.py          Data model + local SQLite (no cloud); export/delete for data rights
│       ├── features.py, anomaly.py        Personal baselines, streaming anomaly scoring
│       ├── guidelines.py                  Pure-Python TF-IDF retrieval over the guideline corpus
│       ├── rules.py                       Deterministic risk rules -> recommendations
│       ├── escalation.py                  Clinician-facing escalation summary builder
│       ├── llm_backends.py, coach.py      Conversational layer (local Ollama if present, else templates)
│       ├── ingestion.py                   Synthetic data generator + CSV importer
│       ├── pipeline.py                    Orchestrates ingest -> features -> rules -> storage
│       ├── api.py                         Optional FastAPI bridge, 127.0.0.1 only
│       └── cli.py                         `python -m health_coach.cli demo|serve|delete-patient|export-patient`
├── nci_pdq_supportive_care_recommendations_clean.jsonl   Active guideline corpus (see provenance below)
├── esmo_early_breast_cancer_recommendations_clean.jsonl  Old corpus, superseded, kept for reference
├── PRIVACY.md                  Honest accounting of data handling: what's covered, what isn't
└── docs/brief.md               Original project spec
```

## Running the backend

The core pipeline uses only the Python standard library - no install needed:

```bash
cd backend
python -m health_coach.cli demo            # seeds 21 synthetic days, prints a risk timeline, opens a local chat
```

If a local [Ollama](https://ollama.com) daemon is running on `127.0.0.1:11434`,
the coach automatically uses it for conversation; otherwise it falls back to a
deterministic template responder. Nothing is ever sent off-device.

Local HTTP bridge (the Flutter app calls this - start it before `flutter run`):

```bash
python -m venv .venv && .venv/Scripts/pip install -r requirements.txt
python -m health_coach.cli serve            # binds 127.0.0.1:8765 only
```

Run the test suite (`pytest`, in the same venv): `pytest -q` from `backend/`.

## Running the Flutter app

```bash
cd health_coaching_app
flutter pub get
flutter run
```

The app now talks to the backend over `127.0.0.1:8765` - start `serve` above
first. On Android/iOS, `HealthService` will prompt for Health Connect/
HealthKit permission and use real steps/HR/sleep if granted, falling back to
simulated numbers otherwise (desktop builds always use simulated numbers -
there's no Health Connect/HealthKit there). Either way, the **risk assessment
and chat replies are real**, computed by the backend's rule engine and
guideline retrieval. If the backend isn't reachable, the AI Coach card and
chat show an honest "can't reach the local coaching service" message instead
of failing silently or fabricating a reply.

Run `flutter analyze` before trusting the Health Connect/HealthKit changes on
a real device - they were carefully reviewed but never actually run on
hardware (see "HealthService and Health Connect setup" above).

**Reaching 127.0.0.1 from the app** depends on the target:
- Desktop build or iOS simulator: `127.0.0.1` already points at the same
  machine, no setup needed.
- Android emulator: either run `adb reverse tcp:8765 tcp:8765` (already
  supported since `network_security_config.xml` allows cleartext to
  `127.0.0.1`/`localhost`), or point `BackendService.baseUrl` in
  `lib/services/backend_service.dart` at `http://10.0.2.2:8765` (the
  emulator's alias for the host machine - also pre-allowed).
- **Physical Android device over USB: `adb reverse tcp:8765 tcp:8765` also
  works here** - it's not emulator-only, it tunnels through the ADB/USB
  connection itself regardless of device type, so the phone's own
  `127.0.0.1:8765` reaches the backend with no LAN exposure and the
  loopback-only guarantee genuinely holds (an earlier version of this
  README claimed otherwise - that was simply wrong, never having been
  checked against real hardware). A LAN IP is only needed for wireless
  debugging without USB, which does trade away the loopback guarantee and
  isn't necessary for same-machine development.

## Architecture (target)

```
Watch  -->  Phone health layer (Health Connect / HealthKit)
              -> Flutter app (local storage, UI)
                  -> local Python service (127.0.0.1 only)
                       - personal baseline + anomaly scoring
                       - guideline-grounded rule engine
                       - conversational coach (template or local Ollama)
                  <- structured summary / chat reply / escalation summary
              <- reminders, risk flags, a clinician-facing summary to show/export
```

Sensor model first, clinical rule engine second, LLM last: the conversational
layer only ever explains and delivers what the deterministic rule engine and
retrieval layer already computed - it does not diagnose from raw numbers.

**This was violated until it was caught in a live demo:** the chat prompt
originally only included today's high-level recommendation text and recent
chat history - no actual sleep/HR/steps numbers at all. Asked "what's the
least I slept," the model fabricated a plausible-sounding "6 hours" instead
of the real 5.1h in that run, because it had no real number to draw from.
Fixed in `coach.py`/`llm_backends.py`: `CoachContext` now carries a
`recent_trend` block (real per-day resting HR/sleep/steps, from
`storage.load_recent_daily_features()`), and the system prompt explicitly
instructs the model to say it doesn't have a figure rather than invent one
when asked about something outside that data. Verified by inspecting the
actual constructed prompt against known ground-truth data, not just by
eyeballing chat replies.

**A 20-question live test battery against the real Ollama model surfaced
two more failure modes in the same family, both now fixed:**

1. **A grounded number with a dangerously wrong conclusion.** Asked "What
   was my heart rate on August 29th?" (a real 128 bpm escalate-level spike),
   the model answered "128bpm. No concerns here! Just a normal day." The
   number was correct - the interpretation wasn't, and nothing tied that
   specific date to what the rule engine had already determined about it.
   Tellingly, the same fact framed as "should I be worried about that
   spike?" got answered correctly five questions later - real fragility
   depending on phrasing. Fixed by annotating each day in `recent_trend`
   with its actual stored risk level when not normal (`storage.
   load_recent_risk_assessments()`, new), so a day the rule engine already
   flagged carries that fact inline, next to the number, instead of relying
   on the model to correctly cross-reference a separate guideline snippet
   against a date.
2. **Fabricated non-numeric citations.** Asked about an ibuprofen
   interaction, the model attributed its answer to the "National
   Comprehensive Cancer Network (NCCN)" - a real organization, never
   actually in `guideline_snippets`, invented from general training
   knowledge and presented as if retrieved. After that pattern was caught
   (`ground_citations()`, checks "Name (ACRONYM)" shapes against what was
   actually retrieved), the model pivoted to citing a bare "the FDA" with
   no parenthetical name at all - same fabrication, different shape, closed
   with a small fixed vocabulary of known health-authority acronyms rather
   than matching arbitrary capitalized text.

Both fixes are deliberately narrow and documented as such in code, not
claimed as complete coverage: `ground_citations()` only catches these two
specific citation shapes. There is also no path today for something a
patient *says* in chat (e.g. distress about continuing treatment) to reach
the rule engine - only wearable metrics can trigger `escalate`, never
conversation content.

**The counting-style gap above got an architectural fix, not another prompt
patch.** "How many days did I sleep less than 6 hours" is a different shape
of problem than average/lowest/highest: the threshold is whatever number the
patient types, so it can't be precomputed in `trend_stats` ahead of time the
way an average can. `coach.py`'s `_try_answer_count_question()` detects this
question shape (a metric + comparator + number, e.g. "less than", "at
least") and answers it with an exact Python filter-and-count over the real
`DailyFeatures`, bypassing the LLM entirely for that turn - `CoachAgent.
handle_message` calls it before ever calling `self.backend.generate()`, and
only falls through to the model if it doesn't match. Re-running the exact
question that miscounted now returns "your sleep was below 6.0h on 4 days:
2026-08-20, 2026-08-22, 2026-08-28, 2026-08-30" - deterministically, every
time, because there's no LLM inference involved at all for this class of
question anymore. Narrow by design: it only matches this specific shape
(metric + comparator + number), so anything phrased differently, or
combined with a second question, still goes through the LLM path as before.

**A fourth live failure, found the same way: invented dates in the
*future*.** Asked "what have been my steps each day for the past seven
days" with only one real recorded day on the books, the model listed that
real day correctly, then invented six more calendar dates - several of them
after "today" - labeled "no data available." Same fix shape again:
`coach.py`'s `_try_answer_daily_breakdown_question()` detects "each
day"/"daily"-style questions and lists only the real rows in `DailyFeatures`,
never padding out to a requested day count with dates that don't exist.

### Responsive UI, a trend/history screen, and a real Android build

Running the app live at a wide desktop viewport (not just a phone-shaped
one) surfaced two UX problems no amount of code review would have caught:
opening the AI coach pushed a full-screen chat that hid the rest of the app
entirely, and a single mobile-shaped column left most of a wide window
looking empty. `lib/screens/home_shell.dart` is a `LayoutBuilder`-driven
responsive root: below 900px it behaves exactly as before (full-screen push,
verified unchanged with a screenshot at real iPhone dimensions); at or above
900px, `TodayScreen` and an embedded `AIChatScreen` render side by side,
always both visible. `AIChatScreen` gained an `embedded` mode (no
Scaffold/AppBar/back button, since there's no pushed route to pop) for this.

Also added: `TrendScreen` + `GET /trend/{patient_id}` - the recent-trend
data that previously only ever surfaced inside chat answers is now charted
(`fl_chart`) with the patient's own rolling baseline as a reference line,
reachable from a chart icon in `TodayScreen`'s app bar.

Writing widget tests for the responsive shell (the project's existing
`test/widget_test.dart` was itself stale - asserting UI text from an earlier
redesign that no longer existed anywhere, and had evidently never actually
been run) surfaced two real layout bugs at real phone width (390px): a
horizontal overflow in the "Ask Coach"/"Care Team" button row and a vertical
overflow in the compact metric cards, both from `Text` widgets with no
`maxLines`/`overflow` guard against a wider-than-expected font or string.
Fixed by wrapping the affected text in `Flexible`/`maxLines: 1` so a tight
fit degrades to truncation instead of a hard render overflow, regardless of
what caused the width to be tighter than expected.

Finally, the Android toolchain that was missing all along got actually set
up - JDK 17, Android SDK cmdline-tools, platform 36, build-tools 28.0.3 -
and a real `app-debug.apk` now builds successfully via `flutter build apk
--debug`. Worth being precise about what that does and doesn't prove:
`flutter doctor` reported the Android toolchain as fully green *before* this
actually worked - the real build then failed three separate times in a row
on a version cascade `flutter doctor` never surfaced (Gradle 8.12 too old,
then the Android Gradle Plugin 8.9.1 too old, then Kotlin 2.1.0 too old,
each only discovered by the next failure after fixing the last). Bumped to
Gradle 8.14, AGP 8.11.1, and Kotlin 2.2.20 - deliberately staying below AGP
9.x, which the build's own warning flagged as requiring a build.gradle.kts
rewrite this project doesn't have. A clean compile is real progress, but it
is not the same claim as "verified on a physical device with real Samsung
Health data" - that still requires the device-specific steps only the
person holding the phone can do (enabling USB debugging, granting Health
Connect permissions, confirming Samsung Health actually syncs to Health
Connect), and hasn't happened yet.

### Running live on real hardware surfaced a fourth deterministic-bypass gap, and prompted a model upgrade

Once the app was actually running on a real phone (over `adb reverse` via
USB, after wireless debugging pairing turned out flakier than expected on
that particular device), a real question exposed a real bug: "what's my
average step per day amount in the past 7 days" contains the phrase "per
day", which matched `_try_answer_daily_breakdown_question`'s trigger before
`_try_answer_windowed_average_question` existed - so the actual ask (a
7-day-windowed average) was silently ignored in favor of dumping all 13 raw
days on record. Fixed by adding a dedicated windowed-average handler,
checked before the daily-breakdown dump, that both recognizes "average"
phrasing and - when a day count is named - slices to the real most-recent N
rows rather than the fixed-size trend window computed once for the whole
conversation. Verified live: the same question now returns "your average
steps was 9894" (the correct 7-day figure), through the real chat pipeline
running against the real backend the phone was already connected to.

Also swapped the default Ollama model from `llama3.2` (3B) to `qwen2.5:14b`
after live testing on real hardware (an RTX 5070 Ti, 16GB VRAM) made the
smaller model's instruction-following limits repeatedly visible in
practice, not just in theory. Worth being honest about what this does and
doesn't change: it's a real capability upgrade, but the deterministic
bypasses and grounding checks earlier in this document exist *because* no
model size fully eliminates small-sample hallucination risk - they still
matter with the larger model, and stay in place regardless of which model
`HEALTH_COACH_OLLAMA_MODEL` points at.

**The very first live message sent to `qwen2.5:14b` immediately found a
real bug in the "steps were 8500" fix from earlier this session.** Asked an
open-ended question, the reply came back as "...strategies that can be a
specific figure I don't have handy. **Prioritize Rest:**..." - a
grammatically broken sentence with a chunk of ordinary prose deleted mid-
paragraph. Root cause: the bidirectional "unit-before-number" pattern added
for "steps were 8500" had no word boundary after the unit token in its
reversed alternative, so "h" (the optional "ours?" suffix left unmatched)
matched the leading letter of any word starting with h - "helpful", "here",
"have" - and then scanned up to 15 characters forward for any digit, which
a markdown numbered list ("1. **Prioritize Rest:**") always supplies. That
digit was never grounded, so `ground_reply` deleted the entire span,
unrelated prose included. Fixed with an explicit `\b` after the unit token
(only a complete "h"/"hours"/"bpm"/"steps" word can start the reversed
match now) and a tighter 8-character gap. Re-verified live with the exact
same question - clean output, numbered list intact - and confirmed the
original "steps were 8500" catch this pattern exists for still works.

### Calories, per-metric history with daily/weekly/monthly rollups, and an honest ECG answer

Requested after seeing the app running live: tap any metric card to see its
history, sortable daily/weekly/monthly; add calories if meaningful; add ECG
if feasible.

**Calories**: added end-to-end - a new `SignalType.CALORIES` signal,
`DailyFeatures.calories`/`calories_baseline`/`calories_zscore`, a Health
Connect/HealthKit read (`ACTIVE_ENERGY_BURNED` /
`HKQuantityTypeIdentifierActiveEnergyBurned`, added to both platforms'
manifests), and a new "Calories" card on the Summary screen. This is a real
schema change to a table (`daily_features`) that already had rows in the
live running database - handled with an idempotent `ALTER TABLE` migration
in `storage.init_db()` (a bare `CREATE TABLE IF NOT EXISTS` is a no-op
against an existing table, so new columns need their own migration path),
verified against the real database this session had already been writing
to, not just a fresh test database.

**ECG: deliberately not implemented, and not faked.** Android's Health
Connect - what `HealthService` reads through - has no ECG/waveform record
type in its public API at all; Samsung's ECG classification (via Galaxy
Watch) is only reachable through Samsung's own proprietary Health SDK, which
the `health` Flutter package doesn't wrap and which Health Connect doesn't
expose to third-party apps. Building a fake ECG card that always shows
placeholder data would violate this project's own core principle
("`ground_reply`... never state a number that doesn't come directly from
the trend data") applied to the UI layer instead of the chat layer. iOS
HealthKit does have `HKElectrocardiogramType`, but it requires a distinct,
Apple-gated entitlement and is unverifiable in a project that has no
functioning iOS build path at all in this environment. Both left out
honestly rather than half-built.

**Per-metric history with daily/weekly/monthly sorting**: new
`lib/screens/metric_history_screen.dart`, reached by tapping any of the
four Summary-screen cards. Backed by `GET /trend/{patient_id}?period=daily|
weekly|monthly` and `features.aggregate_period()` - steps/calories are
*summed* per week/month (total activity is the meaningful number), resting
HR/sleep are *averaged* (summing a vital sign across a week means nothing).
`period_start`/`period_end` are always the full calendar week/month, but
`day_count` says exactly how many real days back that number - a week with
2 real days out of 7 reports `day_count: 2`, never silently implying full
coverage. The existing multi-metric `TrendScreen` (reached via the app
bar's chart icon) kept its daily-only view and just gained a Calories
chart; the new per-metric screen with period sorting is the addition.

## Known gaps / next steps

What's left, now that the app↔backend bridge, real device reads, escalation
delivery, and the guideline corpus are all in place:

1. **Verify `HealthService` against real Samsung Health data on a real
   device.** `flutter analyze` is clean, the app now actually compiles for
   Android (`flutter build apk --debug` succeeds, after fixing a
   Gradle/AGP/Kotlin version cascade `flutter doctor` never flagged), and
   `adb reverse` genuinely works for a USB-connected physical device (an
   earlier version of this README wrongly claimed otherwise). What's left
   is entirely on the device-holder's side: enable USB debugging, confirm
   Samsung Health actually syncs Steps/Heart Rate/Sleep to Health Connect,
   grant the app's Health Connect permission prompt, and confirm real
   numbers appear instead of the simulated fallback (8247 steps/68.5 bpm/
   7h45min). Still the single highest-priority remaining item, but the
   scope of what's actually unverified has narrowed a lot this round.
2. **Clinical review of the rule thresholds** in
   `backend/health_coach/rules.py` - they are prototype placeholders. The
   MIT-BIH and cardio-oncology-corpus work sanity-checked *magnitude*, but
   only a clinician can validate them for real use.
3. **A proactive escalation delivery channel** (local notification when a
   day escalates) - the summary and a manual share button exist now, but
   the patient still has to open the app and tap through.
4. **The privacy items `PRIVACY.md` names explicitly**: a consent flow
   before first `/ingest`, encryption at rest (SQLite is currently
   plaintext), a retention policy, an audit log, and a real legal
   determination of GDPR lawful basis / HIPAA applicability for whatever
   deployment context this eventually has. None of these are code problems
   to solve blindly - they need human/legal input first.
5. **A longitudinal, real-patient-population dataset** to replace MMASH/
   LifeSnaps' healthy-adult baselines with actual oncology-patient
   baselines - both current calibration sources are explicitly noted as
   general/healthy cohorts, not cancer patients. The real lung-cancer Fitbit
   dataset found during dataset research (see Development History, stage 9)
   would be the natural next candidate.

## Development history

A running, honest log of what changed and why, in order. Each stage's full
detail lives in the section it's linked to above - this is the timeline.

1. **Initial assessment.** Read [`docs/brief.md`](docs/brief.md) and the
   pre-existing README, gave an honest current-state summary: a Flutter UI
   showing hardcoded demo numbers, a canned keyword-matched French chatbot,
   and a working-but-disconnected Python backend.
2. **Data-and-fine-tuning strategy.** Discussed how to gather real data and
   whether to fine-tune a model given no dedicated compute. Recommendation:
   don't fine-tune - this architecture is retrieval-grounded by design (see
   "Sensor model first, clinical rule engine second, LLM last" above), so
   the leverage is in retrieval quality and prompting, not model weights.
3. **Local-first dataset/framework research.** Reviewed a set of proposed
   datasets and frameworks (MMASH, DREAMT, BiomedBench, Open Wearables,
   Open mHealth, FHIR, CQL), verified each by web search rather than taking
   the claims on faith, and scoped a recommendation to the project's actual
   local-first constraint - several (Open Wearables, FHIR, CQL) were judged
   premature complexity for a single-user prototype and skipped.
4. **MMASH calibration - first real data integration.** Downloaded MMASH
   (PhysioNet, open access, 22 healthy adults), built
   [`calibrate_from_mmash.py`](backend/scripts/calibrate_from_mmash.py), and
   replaced guessed noise constants in `PatientProfile` (`ingestion.py`)
   with real ones - while being explicit about what a single-session
   dataset structurally *couldn't* supply (day-to-day step variability).
5. **App ↔ backend bridge.** Built `BackendService` (Dart HTTP client),
   wired `TodayScreen` to `/ingest` + `/summary` and `AIChatScreen` to
   `/chat`, deleted the canned French keyword-matched responses, and added
   the Android network-security-config / iOS ATS exceptions loopback HTTP
   needs on real devices (easy to silently forget, since desktop testing
   doesn't need them).
6. **Guideline corpus swap.** Built
   [`build_nci_pdq_corpus.py`](backend/scripts/build_nci_pdq_corpus.py),
   replacing the old ESMO early-breast-cancer *staging* corpus - which was
   both topically wrong (screening/diagnosis criteria, not symptom
   coaching) and copyrighted journal content this project had no right to
   redistribute - with public-domain NCI PDQ supportive-care content.
   Verified retrieval quality directly against `rules.py`'s real queries
   rather than assuming a corpus swap alone was sufficient.
7. **Quickstart.** Consolidated the two separate "run the backend" / "run
   the app" sections into one copy-pasteable end-to-end sequence.
8. **Status assessment against the brief.** Mapped actual progress against
   the brief's 5 objectives and 2 deliverables (not just "does it run") -
   this is what surfaced escalation and privacy as the weakest areas,
   despite the software plumbing being comparatively mature.
9. **Broader dataset research.** Found and verified (or ruled out) further
   candidates: LifeSnaps, MIT-BIH, BIDSleep, Kaggle's Fitbit dataset, and a
   real lung-cancer-patient Fitbit dataset (published mid-2026). DiSCover
   and Kaggle were ruled out - the former isn't publicly downloadable at
   participant level, the latter needs an API login this environment
   doesn't have.
10. **Real longitudinal calibration + escalation + arrhythmia sanity
    check.** Downloaded LifeSnaps and MIT-BIH. Built
    [`calibrate_from_lifesnaps.py`](backend/scripts/calibrate_from_lifesnaps.py),
    superseding MMASH's noise estimates with genuine within-person
    longitudinal ones (and filling in `steps_noise` for the first time -
    MMASH's single-session design never could). Built `escalation.py` (the
    `/escalation` endpoint, a `storage.py` query that didn't exist yet, CLI
    wiring, tests) to close the biggest gap surfaced in stage 8: escalation
    previously produced nothing a patient could show a clinician. Built
    [`analyze_mitbih_tachycardia.py`](backend/scripts/analyze_mitbih_tachycardia.py)
    and documented an honest finding directly in `rules.py`'s comments: the
    `>120 bpm` cutoff has real margin above normal sinus rhythm, but real
    ventricular-tachycardia episodes in that data went as low as ~90 bpm -
    a genuine limitation, not just a caveat for form's sake. Also fixed a
    broken `backend/.venv` left over from a project folder rename, which
    was silently installing new packages to an orphaned path.
11. **Escalation delivery, data rights, real device reads, and a dedicated
    cardio-oncology source - pushed as far as the brief's remaining
    objectives could go without a clinician, a legal review, or physical
    hardware.** Built `escalation_screen.dart` (view + native share sheet
    via `share_plus`), closing the "patient can't actually show anyone"
    gap from stage 10. Added `storage.export_patient_data()`/
    `delete_patient_data()`, `/patient/{id}` API routes, and
    `cli.py export-patient`/`delete-patient` - then wrote
    [`PRIVACY.md`](PRIVACY.md) to state plainly what those do and don't
    cover, rather than let a couple of new endpoints imply more compliance
    than they provide. Rewrote `health_service.dart`: found and fixed a real
    latent bug (the `health` v13 package removed its singleton and requires
    `configure()`, neither of which the original code did), and added the
    Android manifest permissions, `<queries>`, activity-alias, and
    `FlutterFragmentActivity` swap Health Connect actually requires - all
    verified by reading the package's own documentation rather than
    guessing, since this environment has no device to test against. Found,
    verified the CC BY 4.0 license of, and extracted a dedicated
    cardio-oncology position paper
    ([`build_cardio_oncology_corpus.py`](backend/scripts/build_cardio_oncology_corpus.py)),
    closing the "topically adjacent, not precise" cardiac-guideline gap
    from stage 6 - confirmed by re-running the same retrieval query and
    watching the top result change from tangential fatigue content to
    actual arrhythmia-monitoring guidance.
12. **Pre-submission verification pass: ran the test suite, confirmed the
    LLM layer is genuinely live (not just theoretically wired up), fixed
    two real bugs, and closed the largest test-coverage gaps.** Found this
    environment has a local Ollama daemon running with `llama3.2` already
    pulled, so instead of taking "the coach uses a real LLM" on faith, ran
    `OllamaBackend` directly against the exact fabrication scenario stage 11
    fixed and confirmed the reply now cites the real 5.1h figure - codified
    as `tests/test_coach.py::test_ollama_backend_uses_real_trend_data_not_fabrication`
    (auto-skips if no Ollama daemon is reachable, so the suite stays
    portable). Added `tests/test_coach.py`, `tests/test_llm_backends.py`,
    and `tests/test_api.py` (28 tests total, up from 17) covering code that
    had zero coverage before: the `recent_trend` prompt-building logic, the
    deterministic `TemplateBackend` fallback, and the FastAPI bridge. Found
    a real bug while writing that last one: `GET /summary/{patient_id}`
    ignored the `day` query parameter when loading the risk assessment -
    it always returned the *latest* assessment regardless of which day's
    features were requested, so querying an old day could pair that day's
    real measurements with an unrelated, more recent risk level and
    findings. Fixed in `api.py` to look up the assessment for the same day
    the returned features actually came from. Separately, found the AI
    chat screen (`ai_chat_screen.dart`, `quick_suggestions.dart`) still had
    French UI strings left over from the original canned chatbot (see
    stage 5) despite every other screen being English - translated them.
    This wasn't purely cosmetic: the guideline corpus and `guidelines.py`'s
    TF-IDF tokenizer are English-only, so a tapped French suggestion chip
    would silently retrieve zero guideline citations (no cross-language
    keyword overlap), quietly degrading the "guideline-grounded" property
    for exactly the questions the UI was suggesting. `flutter analyze`
    still couldn't be run - no Flutter/Dart SDK in this environment - so
    the Dart changes are reviewed-but-unverified the same way stage 11's
    Health Connect rewrite was.
