# Code index live evaluation

Ordinary tests do not call a paid model. This evaluation is opt-in.

```sh
TEST_RUNNER_SLATE_EVAL_INDEX=1 TEST_RUNNER_SLATE_EVAL_MODEL=gpt-5.5 xcodebuild -project PersonalContext.xcodeproj -scheme PersonalContext -derivedDataPath build -destination 'platform=macOS' -only-testing:PersonalContextTests/CodeIndexEvalTests/testLiveSlateRepositoryIndex test
```

It indexes this repository, writes the generated reference and tool trace under `PersonalContextTests/Scenarios/code-index-traces`, and fails only on structural problems: no published reference, empty entries, or paths that do not exist.

Use the trace to judge whether the reference explains major components, points at real implementation and tests, discloses gaps, and reduces discovery work on a focused question without reducing correctness.
