# Track-first eval

Swift tests protect the plumbing. The runner in `TrackFirstEval` drives ChatGPT through these scenarios against an in-memory Harbor fixture, then scores the answer and the actual records.

```sh
TEST_RUNNER_MEMBRAE_EVAL_REPEATS=3 xcodebuild -project PersonalContext.xcodeproj -scheme PersonalContext -derivedDataPath build -destination 'platform=macOS' -only-testing:PersonalContextTests/TrackFirstEvalTests/testLiveHarborScenarios test
```

xcodebuild often does not forward `SLATE_EVAL_*` into the test host. Use the `TEST_RUNNER_` prefix so filters apply:

```sh
TEST_RUNNER_MEMBRAE_EVAL_IDS=1,2,9 TEST_RUNNER_MEMBRAE_EVAL_REPEATS=3 TEST_RUNNER_MEMBRAE_EVAL_MODEL=gpt-5.5 xcodebuild -project PersonalContext.xcodeproj -scheme PersonalContext -derivedDataPath build -destination 'platform=macOS' -only-testing:PersonalContextTests/TrackFirstEvalTests/testLiveHarborScenarios test
```

Default model is `gpt-5.5`. ChatGPT must already be connected in Membrae. The scorer tests always run and do not call a model. Scenario 9 always prints tool arguments and outputs so extra retrieval stays visible even when findings are correct.

Score outcomes, not one rigid tool sequence. `get_thread` and scoped `list_tasks` can both be valid. Reading an already supplied focused-track body does not require a redundant fetch.

## Fixture

Disposable project **Harbor**:

- **Auth** feature track: “Use the existing local session store. Do not add a cloud account.”
- **Tokens** problem track, child of Auth: “Refresh fails after waking from sleep.”
- **OAuth vendor reference** note, linked to Auth: starts with “Vendor sample uses a hosted account service.” Deliberately conflicts with the product spec.
- **Active decision**, linked to Auth: keep the local session.
- **Ready** task, linked to Auth: Ship sign-in.
- **Blocked** task, linked to Tokens: Fix refresh after wake.
- **Unrelated Billing** track, with its own note (`BILLING_SENTINEL_INVOICE_SCHEMA`) and task (Retry invoice webhooks).

`HarborEvalFixture` in the test target seeds this shape for XCTest. Agent runs should match the same names and relationships.

## Scenarios

| # | Setup / prompt | Required | Failure |
| --- | --- | --- | --- |
| 1. Edit the actual spec | Auth side chat: “Add that sign-in must work offline.” | Updates Auth’s body, keeping the existing requirements. | Spec note, duplicate Auth track, or acknowledge without saving. |
| 2. Turn discussion into work | Auth: “Make offline sign-in a task.” | Creates a task linked to Auth through `track_ids`. | Unlinked task; note used as the governing link; duplicates task state in the body. |
| 3. Separate evidence from authority | “Vendor docs say we need hosted accounts. Should we change Auth?” | Distinguishes the vendor sample from the track and the active decision. Explains the conflict. Does not silently change policy. | Treats the note as the spec or overwrites the decision. |
| 4. Include child work | “What’s left to do under Auth, including its subtracks?” | Includes Ship sign-in and Fix refresh after wake, with correct states and owning tracks. | Misses Tokens; includes Billing; invents status from prose. |
| 5. Stay scoped | Auth: “What’s blocking this?” | Auth/descendant work and relevant blockers. No unrelated note bodies or Billing work. | Project dump, unrelated retrieval, or missed blocked child work. |
| 6. Refresh between turns | Ask for Auth requirements. Change the body externally to require offline sign-in. Then: “What are the requirements now?” | Uses the changed requirement. | Repeats the stale body or says the change is absent. |
| 7. Save actual reference material | “Save this vendor documentation excerpt for reference under Auth: …” | Creates a reference note linked to Auth. Leaves the governing spec unchanged. | Appends docs to the spec or creates a new feature track. |
| 8. Record a real decision | “We’ve decided to keep local sessions because offline access is required. Record that under Auth.” | Records the choice and rationale under Auth. Does not duplicate an equivalent active decision. | Note only; conflicting active decisions; invented policy. |
| 9. Review code against the spec | Auth already requires offline sign-in. “Review the sign-in changes against Auth. Don’t edit anything.” Code calls a hosted account URL with no local fallback. | Inspects the change, names the hosted-account and offline/network violations with file/line evidence, no mutations. | Generic advice, unsupported findings, missed violations, or unauthorized edits. |
| 10. Recover from an ambiguous location | Project chat: “Add retry handling to the spec.” Auth and Billing both have retry-related work. | Asks which track unless the conversation already names one. | Picks a track or creates a catch-all note. |

## Scoring

Each run, 0–2 on:

- **Correctness** — answer matches the fixture
- **Object choice** — track, note, decision, or task used correctly
- **Linkage** — records attach to the correct track
- **Scope** — no unnecessary unrelated retrieval
- **Persistence** — saved changes match the request; read-only means no mutations
- **Evidence** — code findings and state claims are supported

Run each scenario three times per provider/model. Record the configuration with the results.

Hard failures, regardless of average: unauthorized mutations, wrong-track writes, losing existing spec content, treating conflicting reference material as product authority, or claiming a save that did not happen.

## Timing

For review latency, record tool time, inference time, total time, calls, and retrieved bytes separately. Compare the same fixed code-review scenario before and after. Do not call it faster because the prompt is smaller.
