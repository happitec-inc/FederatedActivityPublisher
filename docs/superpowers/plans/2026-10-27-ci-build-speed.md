# CI Build-Time Reductions (Round 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the PR Test job and the stage/prod deploy jobs further, using only changes inside this repository plus one issue on the runner-image repository.

**Architecture:** Workflow and build-script edits only. The Swift build cache keeps using the existing `happitec-inc/public-actions` composites `swift-build-cache-restore` and `swift-build-cache-save` at `main`, with their existing `path`, `key-prefix` and `fix-docker-permissions` inputs. If Open Question Q2 picks the merge, one new script replaces the duplicated integration-test steps. No new workflow, action or cache mechanism.

**Tech Stack:** GitHub Actions on ephemeral tart Linux arm64 runners (4 CPU, 15.6 GiB), the `swift-al2023:6.3` Docker image, SwiftPM (Swift 6.3), SAM.

**Spec:** the scope settled 2026-10-27, restated in Global Constraints below. Timings come from a CI build review of `6d02908`, recomputed from the Actions job API. Run IDs are cited where a number is used.

## Global Constraints

- **Baseline.** `origin/main` at `bbe9fe5`. That commit includes FederatedActivityPublisher#299, which makes the stage integration tests read the `STAGE_TEST_BEARER_TOKEN` secret. Between `6d02908` and `bbe9fe5`, only four files changed: `deploy-stage.yml` (from `:443` on), `run-integration-tests.yml`, `README.md` and `BuildingAndDeploying.md`. Every file:line reference is to `bbe9fe5`.
- **Toolchain.** Swift 6.3 only. No Swift 6.4, no handler consolidation.
- **Pins.** `Package.resolved` is regenerated only by the Resolve Packages workflow (`resolve-packages` label, `.github/workflows/resolve-packages.yml`), never with a local toolchain.
- **Validation.** PR CI (the Test workflow) and the `lambda-build` label (`.github/workflows/lambda-build.yml`). Deploy-workflow changes are validated by the first post-merge run; fix forward. Never use, clone, boot or SSH a runner VM or runner image. Never run `aws` or `sam deploy` locally.
- **Caches.** Only `happitec-inc/public-actions/swift-build-cache-restore@main` and `.../swift-build-cache-save@main` for Swift build state. Do not add `actions/cache` steps for Swift state and do not write a new cache mechanism. The existing `actions/cache@v5` steps for `/tmp/docker-image.tar` stay as they are.
- **Out of scope.** Promoting stage zips to prod. Moving `detect` to a hosted runner. Runner-image changes (Task 1 only files an issue).
- **Public repository.** Commit messages, PR bodies and run titles are short and about the code. No closing keywords; reference issues as "Refs FederatedActivityPublisher#N".
- **Evidence grade.** Every saving and premise is tagged `[measured]` (from a CI log, the job API, `gh cache list` or a local run), `[inferred]` (mechanism known, size not measured) or `[unverified]` (not yet checked; the named step measures it).
- **Negative control.** A check counts only after its control has been seen to fail, or the PR description says why no failing control exists.
- **Docs.** Each PR updates `Sources/ActivityPubCore/Documentation.docc/BuildingAndDeploying.md` where it changes what that page describes.

## Review Focus

1. **Cache `path` drift.** `actions/cache` derives an entry's version from its `path` list, so a restore whose `path` differs from the save's never matches, and nothing reports it: every run is silently cold. Task 6 changes `path` at six call sites. Its Step 4 checks all of them by grep, and Step 7 checks the post-merge restore log.
2. **Root-owned files at save time.** With a multi-line `path`, the save composite's `chown` step never runs (Open Question Q1). The fast path builds as root (`deploy-stage.yml:146-150`, no `--user`). Task 6 Step 3 moves its `chown` into a separate `if: always()` step.
3. **Warm or cold validation runs.**
   - Whether a main-scoped Swift build entry exists depends on recent stage deploys. On 2026-10-27, `gh cache list` held only a tag-scoped entry. Stage deploy run 40576202859, attempt 2, was still in progress and would save a main-scoped one.
   - Re-record `gh cache list` when implementation starts, and treat "warm" or "cold" as a measured fact for each run.
   - PR A orders Task 6 (the `path` change) first. Every `lambda-build` run on a PR A commit after that is cold whatever main holds, because the cache version no longer matches. The cold-to-cold receipts in Tasks 7 and 8 rely on that.
4. **Integration-test failure semantics, if Q2 picks the merge.** A failing integration test then turns the deploy job red after the deploy has happened, and re-running that job re-runs the deploy. Task 9 Step 6 records this in the PR body.
5. **Fast-path update race, if Q2 picks the merge.** `aws lambda update-function-code` returns before the update completes. Today the separate job's start-up (~57 s VM start plus ~33 s image restore and load) hides that. Task 9 Step 2 adds an explicit wait.

---

## Cache budget

These numbers drive Task 6 and the decision to drop the dependency-clone cache (see Deferred).

| Quantity | Value | Grade |
|---|---|---|
| Repository cache cap | 10 GB, from GitHub Actions' cache documentation | documented; GB vs GiB not checked |
| Swift `.build` entry, compressed | 5,783,369,734 B (`gh cache list`, 2026-10-27; created 2026-10-22T04:24:39Z) | [measured] |
| Docker image tar entry | 1,285,426,441 B (restored in run 39718739545) | [measured] |
| The 19 zips inside `.build` | 674,325,891 B, already compressed, so they shrink about 1:1 in the cache archive | [measured] |
| `.build/lambda-staging`, uncompressed | unmeasured; at most the 19 `bootstrap` binaries plus 2 × 19 OpenSSL libs | Task 2 measures it |

**Over the cap at every full-path save.**
- The save key ends in `github.sha`, so each full-path deploy saves a new `.build` entry while the previous one still exists.
- At save time the repository holds 5.78 + 5.78 + 1.29 = 12.85 GB. That is over the cap on every full-path deploy, whatever eviction order applies `[measured sizes]`.
- **Which entry goes, and when, is `[unverified]`.** In run 39718739545, the `build` job saved a new `.build` entry at 03:53:31, over the cap by this arithmetic. Yet the `integration-tests` job restored the Docker tar at 03:56:10. Either eviction is not immediate, or another entry went first.
- Task 6 Step 7 records `gh cache list`, with timestamps, right after a save and again at the start of the next deploy. That separates delayed eviction from a surviving entry.

**After Task 6, a rough bound.**
- The compressed `.build` entry loses about the zips (0.67 GB, incompressible), plus the compressed size of `lambda-staging`. That is smaller than Task 2's uncompressed figure, because the binaries compress.
- That puts the entry somewhere in 4.4–5.1 GB `[inferred; mixed bases, rough]`.
- At save time: two entries plus the Docker tar = 10.1–11.5 GB, still at or over the cap. Everything stays under the cap only if the entry falls to about 4.36 GB or less.
- Task 6 Step 7's measured entry size is the real receipt.

**Why the dependency-clone cache is dropped.**
- A separate `.build/repositories` entry would be saved only on cold builds, which can be weeks apart, and read only by PR Test runs.
- With eviction running at every full-path save, whether such an entry survives is unknown `[unverified]`.
- A size-based stop check can't fire, because eviction keeps the total under the cap. The only check that can fail is whether the entry is still listed after the next full-path deploy.
- With the cap already exceeded on every deploy, adding a second copy of `.build/repositories` (which the `.build` entry already contains) isn't the smallest mechanism this round. Task 2 records its size R for the Deferred decision.

---

## PR grouping

| PR | Tasks (commit order) | Validated by |
|---|---|---|
| — | 1 (runner-image issue), 2 (measurements) | no merge |
| PR A: Test job, prod cache, build script, cache slimming | 3, 4, 5, 6, 7, 8 | Test workflow; `lambda-build` label (cold from Task 6 on); two post-merge stage deploys |
| PR B: integration tests (only if Q2 picks the merge) | 9; then 10 (measurement) | the first post-merge full and fast stage deploys |
| PR C: dead `APIClient` target | 11, after reply-threading step 0's implementation merges | `resolve-packages`, then `lambda-build` (cold) |

PR A's first post-merge deploy is cold because of Task 6's `path` change, and PR C's because of its `Package.resolved` change. No other PR in this plan forces a cold deploy.

---

### Task 1: Issue on the runner image for preinstalled Swift 6.3

**Files:** none in this repository.

- [ ] **Step 1: File an issue on `happitec-inc/TartRunnerKit`.** Include the metadata comment that repository's issue automation requires. Title: `Linux runner image: preinstall Swift 6.3 and the Swift build apt packages`. The body states these facts and no proposed implementation:
  - The FederatedActivityPublisher Test job (`.github/workflows/test.yml`) spends 35–49 s on every run installing these on a fresh VM `[measured]`:
    - "Install Swift dependencies" (`test.yml:31-36`): 16–25 s.
    - "Install Swift" (`test.yml:38-51`): 18–24 s. The `swift --version | grep -q "6.3"` check fails on the fresh VM, so the tarball downloads every time.
    - Run IDs: 39729400471, 39717290454, 39708039693, 39822228060.
  - The packages are `binutils gcc g++ libc6-dev libcurl4-openssl-dev libssl-dev libxml2-dev pkg-config` (`test.yml:34`).
  - The toolchain is `swift-6.3-RELEASE-ubuntu24.04-aarch64.tar.gz` (`test.yml:45`), extracted with `--strip-components=2` into `/usr/local`.
  - The job also replaces `/usr/include/unicode` with Swift's bundled ICU headers (`test.yml:53-62`). An image that preinstalls Swift needs the same header state, or the job keeps doing that step.
  - `.github/workflows/run-integration-tests.yml:67-98` repeats the same three steps.
- [ ] **Step 2:** No negative control applies to filing an issue. Record the issue URL in PR A's description.

---

### Task 2: Measurements before PR A (pre-planning gap, `.build` composition)

**Files:** a throwaway branch only; nothing merges.

The ~46 s gap before "Planning build" appears in three logs `[measured]`:
- cold stage, 02:28:41–02:29:32 (run 39710962177);
- warm stage, 03:50:51–03:51:37 (run 39718739545);
- Test, 05:48:11–05:48:57 (run 39729400471).

Whether it is manifest/graph load or plugin evaluation is unknown. Task 6 also needs the `.build` composition. One dispatch measures both. The dispatch restores main's entry if one exists (Review Focus 3); record from its restore log whether it ran warm or cold. Either way works: a warm run shows the composition of the cached tree, and a cold run shows a fresh one.

- [ ] **Step 1:** `git switch -c measure/build-composition origin/main`. Make two changes:
  - In `scripts/build-all-lambdas.sh:107`, add `-v` to the build invocation only, not to `BUILD_ARGS`. `BUILD_ARGS` is also used by the `--show-bin-path` call at `:108`, which captures stdout into `BIN_PATH`; verbose output there would break packaging.
  - In `lambda-build.yml`, after "Verify Lambda zips" (`:64-65`), add a step with `if: always()`, so it runs even if packaging fails, whose commands give each measured path its own `du` call. GNU `du` prints nothing for an operand that an earlier operand already counted, so `.build/*` would swallow `.build/plugins/AWSLambdaPackager`:
    ```bash
    for p in .build/lambda-staging .build/plugins/AWSLambdaPackager .build/repositories .build/checkouts .build; do du -sb "$p"; done
    du -sb .build/*; tar -cf - .build | wc -c
    ```
  Commit and push the branch. Do not open a PR.
- [ ] **Step 2:** `gh workflow run lambda-build.yml --ref measure/build-composition`. The workflow has `workflow_dispatch` (`lambda-build.yml:13`) and is on the default branch.
- [ ] **Step 3: Gap.** `gh run view <run-id> --log > verbose.log`. Find the last line before `Planning build`. Record, with timestamps:
  - each command SwiftPM ran inside the gap (`swiftc` manifest compiles, plugin compiles and runs, `git` invocations);
  - the duration of each.

  **Negative control:** the same window in the non-verbose run 39718739545 shows no per-command lines. If the verbose log also shows nothing inside the gap, `-v` did not reach the build. Check `BUILD_ARGS` before drawing any conclusion.
- [ ] **Step 4: Composition.** From the loop's lines, record:
  - the excluded share, `S = du(.build/lambda-staging) + du(.build/plugins/AWSLambdaPackager)`, in bytes and as a fraction of `du(.build)`, all on the same uncompressed basis. S is the number Task 6's gate uses;
  - R, the size of `du(.build/repositories)` (for Deferred).

  **Negative control:** the loop line for `.build/plugins/AWSLambdaPackager` must be present, and must be at least the sum of the 19 zip sizes that the same run's "check outputs" phase prints (`build-all-lambdas.sh:160`). The baseline is 674,325,891 B.
  - A missing line means the operands overlapped. Fix the command. Do not read the gap as zero.
  - A smaller number means `du` measured a different tree.

  The `tar | wc -c` figure is the uncompressed archive size, for context only. Never compare it with the compressed "Cache Size" in a restore log.
- [ ] **Step 5:** Delete the remote branch. Post both tables as a comment on PR A.

---

### Task 3 (PR A): Delete the zero-test root `IntegrationTests` step

Refs FederatedActivityPublisher#296.

**Files:**
- Modify: `.github/workflows/test.yml:70-72` (delete the step "Run integration tests (non-network)")

The step runs `swift test --filter IntegrationTests` with `continue-on-error: true`. The root package has only `Tests/ActivityPubCoreTests`; the integration tests live in `integration-tests/Package.swift`. Its log ends with `warning: No matching test cases were run` and `Test run with 0 tests in 0 suites`.

- [ ] **Step 1: Negative control, before the edit.** In the log of "Run integration tests (non-network)" on PR A's first push, confirm `Test run with 0 tests`. That is the evidence that deleting it loses nothing. If any count other than 0 appears, stop: a root integration test exists and this task is wrong.
- [ ] **Step 2:** Delete `test.yml:70-72`.
- [ ] **Step 3: Timing receipt.** The Test job on the next push drops by 78–129 s against the four baseline runs `[measured]`. The Test job uses no Swift cache, so the cache state doesn't affect this receipt.
- [ ] **Step 4:** Commit `ci: drop the root integration-test step that runs no tests`.

---

### Task 4 (PR A): Test job builds only the test product

**Files:**
- Modify: `.github/workflows/test.yml:64-65` ("Run unit tests")

Today `swift test --filter ActivityPubCoreTests` builds every product: 19 debug handler links, `ActivityProvisioner` and `APIClient`. Handler links appear at 05:47:13–05:47:23 in run 39729400471, against 0.5 s of test execution. Expected saving: 10–25 s `[inferred]`.

- [ ] **Step 1:** Replace the step with two steps:
  - "Build unit tests": `swift build --product federated-activity-publisherPackageTests`. The package name is `federated-activity-publisher` (`Package.swift:6`). SwiftPM's synthesized test product name is `<name>PackageTests` `[unverified]`; Step 2 measures it.
  - "Run unit tests": `swift test --skip-build --filter ActivityPubCoreTests`. `--skip-build` is listed by `swift test --help` (checked against a local Swift 6.4.2 help text; Step 2 exercises the CI 6.3 toolchain).
- [ ] **Step 2: Check.** On PR CI:
  - "Build unit tests" succeeds;
  - its log has no `Linking` line for any `*Handler`;
  - "Run unit tests" reports the same `Test run with N tests` count as the last baseline run.

  If SwiftPM rejects the product name, stop and report it. Drop this task from PR A rather than substituting another flag.
- [ ] **Step 3: Negative control.** Push a throwaway commit that adds `#expect(Bool(false))` to one existing test in `Tests/ActivityPubCoreTests`. "Run unit tests" must go red, which proves `--skip-build` ran the freshly built bundle. Revert with a new commit.
- [ ] **Step 4: Timing receipt.** The two steps together, against the baseline "Run unit tests" (308–463 s).
- [ ] **Step 5: Docs.** `BuildingAndDeploying.md:119` ("Runs the `ActivityPubCoreTests` unit test suite on every pull request.") stays accurate; no edit.
- [ ] **Step 6:** Commit `ci: build only the test product before swift test`.

---

### Task 5 (PR A): Prod restores the build cache but does not save it

Refs FederatedActivityPublisher#297.

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:74-78` (delete the step "Save Swift build cache")
- Modify: `BuildingAndDeploying.md:52` ("The build steps are identical to the full path in `deploy-stage.yml`.")

Prod run 39721690715 spent 58 s saving `[measured]`. A release-triggered run saves under the tag's ref. GitHub's documented cache scoping lets main read only main's entries, so that entry has no later reader `[inferred from GitHub's docs, not tested]`.

- [ ] **Step 1:** Delete `deploy-prod.yml:74-78`. Keep "Restore Swift build cache" (`:63-66`).
- [ ] **Step 2: Docs.** Change `:52` to say the build matches the full path except that prod restores the Swift build cache without saving it, and why: a tag-scoped entry has no reader and pushes main's entry out under the cap.
- [ ] **Step 3: Negative control (historical, not current state).**
  - The failing control is the last prod run before the change. Run 39721690715's "Save Swift build cache" step created the entry whose key ends `6d029082…` at 2026-10-22T04:24:39Z, and `gh cache list` listed it on 2026-10-27 `[measured]`.
  - Record that run's save-step log line and the listing in the PR description.
  - This doesn't depend on what the cache holds when PR A is implemented. A later stage deploy may have added a main entry by then (Review Focus 3).
- [ ] **Step 4: Check (after the next release).**
  - The prod run has no save step.
  - `gh cache list` shows no entry created between that run's start and end times.
  - Its "Restore Swift build cache" logs a restore from a main-scoped key, if any main entry exists then. If none exists, the restore misses, and that miss is not this task's failure.
- [ ] **Step 5: Timing receipt.** The prod job loses the 58 s save `[measured]`.
- [ ] **Step 6:** Commit `ci: prod restores the Swift build cache without saving it`.

---

### Task 6 (PR A, first build-path commit): Slim the `.build` cache

**Files:**
- Modify: `.github/workflows/deploy-stage.yml:136-139`, `:154-158` (fast-deploy restore/save), `:152` (chown), `:289-292`, `:300-304` (build restore/save)
- Modify: `.github/workflows/deploy-prod.yml:63-66` (restore; Task 5 removes the save)
- Modify: `.github/workflows/lambda-build.yml:53-56` (restore)
- Modify: `BuildingAndDeploying.md:272` (the `.build` cache paragraph)

**Interfaces:**
- Produces: the cache `path` value used at every Swift build cache call site (exact text, one entry per line):
  ```
  .build
  !.build/lambda-staging
  !.build/plugins/AWSLambdaPackager
  ```

Both excluded paths are rebuilt every run:
- `build-all-lambdas.sh:118` runs `rm -rf "$STAGING_DIR" "$OUTPUT_BASE"` before staging. `STAGING_DIR` is `.build/lambda-staging` (`:31`) and `OUTPUT_BASE` is `.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager` (`:30`). `zip_one` recreates both with `mkdir -p` (`:125`).
- `build-selective.sh` recreates them per target (`:100`, `:105`).
- The fast path's bundling and update steps (`deploy-stage.yml:163-180`, `:204-242`) read only the targets it just built.

Only `.build/plugins/AWSLambdaPackager` is excluded; other `.build/plugins/*` directories hold plugin build state.

- [ ] **Step 1: Gate on Task 2's S (same uncompressed basis).** If S is under 500,000,000 B, stop. Report that the saving is below the estimate, and don't change six call sites for it. The zips alone measured 674,325,891 B, so the gate is expected to pass. It guards against a wrong premise about where the zips live.
- [ ] **Step 2:** At each of the six call sites, pass the `path` value above. Both composites forward `path` verbatim to `actions/cache` (`path: ${{ inputs.path }}`, restore `action.yml:29`, save `action.yml:36`). `actions/cache` documents multi-line `path` with `!` exclusions. See Open Question Q1.
- [ ] **Step 3: Fast-path ownership.** Move `sudo chown -R $(id -u):$(id -g) .build` out of "Build changed targets in Docker" (`deploy-stage.yml:152`) into its own step with `if: always()`, before "Save Swift build cache". Pass `fix-docker-permissions: 'false'` at both save sites. With the multi-line `path`, the composite's `[ -d "${{ inputs.path }}" ]` (save `action.yml:28`) is false and its `chown` is skipped anyway; the explicit input makes that visible. The full-path build runs as the runner uid (`scripts/in-build-image.sh:23`), and `lambda-build.yml:67-69` asserts no root-owned files.
- [ ] **Step 4: Check.** `grep -n -A3 'swift-build-cache-' .github/workflows/*.yml` shows the identical three-line `path` under all six uses.
- [ ] **Step 5: Docs.** In the `:272` paragraph, add the two exclusions and why they are excluded: they are rebuilt from scratch every run. Add that every restore and save must pass the same `path`, or the restore never matches.
- [ ] **Step 6: Expected in PR A's `lambda-build` runs from this commit on.** Cold: the restore logs "Cache not found", because no entry with the new `path` exists yet. This holds whether or not main has a warm entry under the old `path`.
- [ ] **Step 7: Post-merge check, over two stage deploys.**
  - The first full-path deploy after merge saves the new entry from a cold build.
  - Record `gh cache list` right after that save, then again at the start of the next deploy, with each entry's created and last-accessed times.
  - The next deploy, full or fast, must restore the new entry with a key match. "Cache not found" there means a `path` mismatch somewhere (Review Focus 1). That is the failing signal.
  - Record the new entry's compressed size against 5,783,369,734 B, and which entries were present in each listing. That is the receipt for the eviction behaviour and for the deferred fixed-key item.
- [ ] **Step 8: Timing receipt.** Restore plus save, against 75 s + 66 s (run 39718739545). Expected saving: 35–55 s `[inferred]`, scaled by the measured shrink.
- [ ] **Step 9:** Commit `ci: keep never-reused Lambda staging out of the build cache`.

---

### Task 7 (PR A): Drop the separate `swift package resolve`

**Files:**
- Modify: `scripts/build-all-lambdas.sh:95-100` (delete the "resolve" phase), `:9-11` (header: drop item 2 and renumber)
- Modify: `BuildingAndDeploying.md:342` ("Resolves the package once, against the committed `Package.resolved` …")

`SWIFTPM_FLAGS` (`:37`) includes `--force-resolved-versions`, and the build at `:106-107` passes `"${SWIFTPM_FLAGS[@]}"`, so `swift build` resolves against the committed pins itself. The flag is listed by `swift build --help` (local 6.4.2). Phase cost: 9 s warm (run 39718739545), 127 s cold (run 39710962177) and 177 s cold (run 39706774240, the cold baseline Steps 4 and 5 use) `[measured]`. On a cold build most of that is the clone, which moves into the build phase rather than disappearing. The saving is at most the duplicated work `[inferred]`.

- [ ] **Step 1:** Delete the phase. Keep `SWIFTPM_FLAGS` unchanged.
- [ ] **Step 2: Docs.** Rewrite `:342`: `swift build --force-resolved-versions` resolves against the committed `Package.resolved` as part of the build, so there is no separate resolve step. Renumber the list that follows.
- [ ] **Step 3: Check.** Add the `lambda-build` label on a commit that includes Task 6, so the run is cold (Task 6 Step 6). Expected:
  - green;
  - "Package.resolved unchanged by the build" (`lambda-build.yml:61-62`) passes. That step is the real guard that the pins are honoured;
  - the "Phase timings" table lists no `resolve`.
- [ ] **Step 4: Effect check.** The run is cold, so the dependency fetch lines (`Fetching https://github.com/awslabs/aws-sdk-swift…`) must appear inside the `build` phase. In the cold baseline run 39706774240 they appear inside `resolve`. This shows the build did the resolution itself.

  A deleted `Package.resolved` would fail both before and after this change. It shows that pins are enforced, not that this change works, so it is not used as this task's control.
- [ ] **Step 5: Timing receipt (cold-to-cold).** `build` plus `stage+zip` phases against the cold baseline: resolve 177 s + build 261 s + zip 11 s = 449 s (run 39706774240, job 10m24s).
- [ ] **Step 6:** Commit `build: let swift build resolve against the pins`.

---

### Task 8 (PR A): Byte-reproducible zips

**Files:**
- Modify: `scripts/build-all-lambdas.sh:120-131` (`zip_one`), `:155-171` ("check outputs" phase)

Today `cp` at `:126` gives `bootstrap` a fresh mtime, and `zip -X` (`:130`) still stores mtimes. Identical binaries therefore produce different zips. `sam package` re-uploads all 19 (~674 MB), and CloudFormation sees 19 changed code keys. Run 39718739545 changed only `.github` files and still spent 21 s in `sam package` and 58 s in `sam deploy` `[measured]`.

The `touch` form is `TZ=UTC touch -h -t 198001010000`, which is 1980-01-01T00:00:00Z, the earliest time a zip timestamp can hold.
- `-t` is accepted by both BSD `touch` (macOS) and GNU `touch` (AL2023). BSD `touch` rejects `-d @<epoch>`.
- So the local control and the script use one identical command.
- `TZ=UTC` goes on both the `touch` and the `zip`: zip stores local time, so the two must agree.

- [ ] **Step 1: Local packaging control, on macOS, no CI cost.** In a scratch directory, with a file named `bootstrap` and two files under `lib/`:
  - Zip with today's command (`zip -q -X -r out.zip bootstrap lib`), `touch` the files to a new time, and zip again. The two `shasum -a 256` values must differ. This is the failing control.
  - Then run Step 2's `touch` and `zip` commands twice, refreshing the mtimes in between. The two hashes must match.

  Run on 2026-10-27 with macOS `/usr/bin/zip`: the old form gave two different hashes, and the new form gave identical ones `[measured]`. Step 4 is the in-image check.
- [ ] **Step 2: `zip_one`.** After the existing copies and `chmod`:
  - `TZ=UTC touch -h -t 198001010000 bootstrap lib/libcrypto.so.3 lib/libssl.so.3`, run inside the stage directory;
  - then `TZ=UTC zip -q -X -D "$out_zip" bootstrap lib/libcrypto.so.3 lib/libssl.so.3`: no directory entries, explicit file order.

  `scripts/verify-lambda-zips.sh` unzips (`:74`) and checks `lib/<name>` (`:98-100`), so it still covers the layout without a `lib/` directory entry.
- [ ] **Step 3: Hashes in "check outputs".** For each handler, print the zip's `sha256sum` and the `sha256sum` of `unzip -p "$z" bootstrap`, next to the existing size. `verify-lambda-zips.sh` already relies on `unzip` in the image.
- [ ] **Step 4: Reproducibility check.** Two cold builds of PR A's head SHA, which includes Task 6; about 10 minutes each:
  - Run `gh workflow run lambda-build.yml --ref <PR A branch>`, and start the second run only after the first finishes. Dispatches on one ref share a concurrency group with `cancel-in-progress: true` (`lambda-build.yml:17-19`).
  - Diff the two hash lists.
  - **Zip hashes identical:** the change works. Record it.
  - **Zip hashes differ, `bootstrap` hashes identical:** packaging is still non-deterministic inside the image. Fix it before merge.
  - **`bootstrap` hashes differ:** the Swift binaries are not reproducible across two builds of the same source. Fixed mtimes then cannot give identical zips, and Step 5's saving does not occur. Keep Steps 2–3 (harmless, and the hashes stay useful), record which handlers differ, and stop there. Linker determinism is not in this plan.
- [ ] **Step 5: Timing receipt (post-merge).** On the next stage deploy whose change set does not touch Swift sources:
  - `sam package` should log a skip for each unchanged artifact instead of an upload `[unverified: exact SAM wording]`, and should take under 21 s;
  - the `sam deploy` change set should not list the 19 functions' code as changed.
  - Saving: 20–50 s `[inferred]`.
- [ ] **Step 6:** Commit `build: reproducible Lambda zips and per-zip hashes`.

---

### Task 9 (PR B, only if Q2 picks the merge): Run integration tests inside the deploy jobs

**Files:**
- Create: `scripts/run-stage-integration-tests.sh`
- Modify: `.github/workflows/deploy-stage.yml`:
  - delete the `integration-tests` job (`:369-473`);
  - in `fast-deploy`, add a wait to "Update Lambda functions directly" (`:204-242`) and add a final step;
  - in `build`, add a final step after "Print stack outputs" (`:361-367`).
- Modify: `BuildingAndDeploying.md:19`, `:38`, `:252` (integration tests described as running after either path)

**Interfaces:**
- Produces: `scripts/run-stage-integration-tests.sh`.
  - No arguments.
  - Reads `AWS_REGION`, `TEST_BEARER_TOKEN` and `TEST_HANDLE_DOMAIN` from the environment.
  - Expects AWS credentials configured, `aws` on `PATH`, and the image `swift-al2023:6.3` loaded.
  - Exits 0 on pass, 1 on fail.

On the warm full path:
- the `integration-tests` job started 57 s after `build` finished;
- it then spent 16 s restoring and 17 s loading the image before a 42 s test `[measured]` (run 39718739545).

Both deploy jobs already have the image loaded and AWS configured:
- fast-deploy: `:113-128`, `:182-202`;
- build: `:272-279`, `:309-314`; `aws` is used at `:348`.

- [ ] **Step 1: Write the script.** It starts with a header like `build-selective.sh:2-9`: a purpose line, a `Usage:` example, and the inputs above. It behaves like "Get stack outputs" and "Run integration tests in Docker" (`:429-473`):
  - reads `ApiEndpoint` and `ClientApiUrl` from stack `activity-app-stage`;
  - runs `swift test` in `swift-al2023:6.3` with the repository mounted at `/workspace` and `-w /workspace/integration-tests`, passing the four `TEST_*` variables;
  - keeps the pass/fail parsing from `:466-473`, including the FoundationNetworking teardown case.

  It takes the token from `TEST_BEARER_TOKEN`, as the current step does (`:447`), and never reads SSM. Two differences from today:
  - `docker run` adds `--user "$(id -u):$(id -g)" -e HOME=/tmp`, as `scripts/in-build-image.sh:22-27` does, so `integration-tests/.build` is not root-owned.
  - The tests now compile against the substituted `openapi.yaml`, because both jobs run "Substitute domain variables". The tests pass `serverURL` from `TEST_API_URL` and never use the generated `Servers` values (`grep -rn "Servers\." integration-tests/Tests` finds nothing), so this doesn't change what they hit.
- [ ] **Step 2: Fast-path wait.**
  - The first command of the update step is `aws lambda wait help | grep -qw function-updated-v2 || { echo "waiter function-updated-v2 not available"; exit 1; }`. This fails before any function is updated if the runner's CLI lacks the waiter.
  - After each `aws lambda update-function-code`, run `aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME" --region $AWS_REGION`.
  - The waiter is `[unverified]` until the first fast-path run (Task 10). No fast-path run has happened in the last 25 stage deploys, so that check is where it first shows up.
- [ ] **Step 3:** In both jobs, add the final step "Run integration tests", with this `env:`:
  - `TEST_BEARER_TOKEN: ${{ secrets.STAGE_TEST_BEARER_TOKEN }}`
  - `TEST_HANDLE_DOMAIN: stage.${{ vars.HANDLE_DOMAIN }}`

  It runs `bash scripts/run-stage-integration-tests.sh`. Delete the `integration-tests` job (`:369-473`); nothing else `needs` it.
- [ ] **Step 4: Failing control, local, before merge.** Make no real AWS call:
  ```bash
  env -i PATH="$STUBS:/usr/bin:/bin" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null \
    TEST_BEARER_TOKEN=x TEST_HANDLE_DOMAIN=stage.example.com AWS_REGION=us-east-1 \
    bash scripts/run-stage-integration-tests.sh
  ```
  - `$STUBS` holds an `aws` stub that prints a placeholder URL, and a `docker` stub.
  - With a `docker` stub that prints a `Test Suite ... failed` transcript, the script must exit 1.
  - With a stub that prints `passed with 0 issues`, it must exit 0.
- [ ] **Step 5: Post-merge check (full path).** The first stage deploy after merge shows:
  - the "Run integration tests" step, with `Test Suite` lines;
  - three jobs: `detect`, `build`, and `fast-deploy` (skipped).
- [ ] **Step 6: Docs and PR body.**
  - Rewrite `:19`, `:38` and `:252`: the integration tests are now the last step of whichever deploy job ran.
  - Add that dispatching `run-integration-tests.yml` with the input `environment=stage` re-runs them without redeploying.
  - In the PR body, state the changed failure semantics (Review Focus 4).
- [ ] **Step 7: Timing receipt.** Whole-workflow wall time on a warm full path, against 10m10s. Expected about −90 s `[measured components]`.
- [ ] **Step 8:** Commit `ci: run stage integration tests in the deploy job`.

---

### Task 10 (after PR A, and after PR B if it exists): Measure one fast-path deploy on tart

**Files:** none.

No fast-path run has happened since the tart move (the last 25 stage runs were full or skipped). The fast path carries Task 6's ownership change (and Task 9's test step and waiter, if PR B exists), which nothing else validates. FederatedActivityPublisher#288 also applies: `VerifyCredentialsHandler` is missing from the fast path's handler lists, so a core-only change leaves it stale.

- [ ] **Step 1:** At the first stage deploy whose `detect` output is `path=fast`, record:
  - the per-target `Completed: <T> (Ns)` lines (`build-selective.sh:109`);
  - the restore, build, save and test step times;
  - whether each `swift build --product` (`build-selective.sh:92`) pays Task 2's gap;
  - whether the change set touched `ActivityPubCore`, in which case FederatedActivityPublisher#288 applies.
- [ ] **Step 2:** Comment the table on the last merged PR of this plan. No change is planned from it here.
- **Negative control:** the run's `detect` log must say `Fast path:`. A full-path run does not count.

---

### Task 11 (PR C): Remove the dead root `APIClient` target

**Files:**
- Delete: `Sources/APIClient/` (`Exports.swift`, `openapi-generator-config.yaml`, the `openapi.yaml` symlink)
- Modify: `Package.swift:239-249` (target) and `:38` (`swift-openapi-urlsession` entry). Keep `:36-37`; see the sequencing below.
- Modify: `Sources/ActivityPubCore/Documentation.docc/GettingStarted.md:50`, `:57` (tree lines naming `Sources/APIClient/`)
- Modify: `Package.resolved` (from the workflow artifact only)
- Do not touch: `integration-tests/`, which keeps its own `APIClient`

**Nothing at root depends on it.**
- `grep -rn APIClient` outside `integration-tests/`, `.git` and `docs/superpowers/` finds:
  - `Package.swift:241`;
  - `scripts/detect-changed-targets.sh:114` (a skip branch);
  - `scripts/test-detect-changed-targets.sh:59-62` (its test);
  - `GettingStarted.md:50`, `:57`;
  - a comment at `deploy-stage.yml:453` naming `integration-tests/Sources/APIClient`. It stays correct, and Task 9 deletes it if PR B lands.
- No target lists `"APIClient"` as a dependency.
- `swift-openapi-runtime`, `-urlsession` and `-generator` are named only by the `APIClient` target (`Package.swift:243-247`).
- Leave the `detect-changed-targets` lines. With the directory gone they never match, and removing them would turn a hypothetical future `Sources/APIClient/` change into a fast-path build of a non-Lambda product.

**Interaction with reply-threading step 0 (plan PR FederatedActivityPublisher#294, approved, not merged). This conflicts.** Step 0's Task 1:
- **raises**, not removes, `swift-openapi-generator` to `from: "1.11.1"` and `swift-openapi-runtime` to `from: "1.11.0"`, editing `Package.swift:36-37` in place;
- adds `swift-openapi-async-http-client` and five other entries;
- adds `OpenAPIRuntime` and `OpenAPIAsyncHTTPClient` to `ActivityPubCore`.

Its Task 4 puts `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")` on `ActivityPubCore`. Once step 0's implementation lands:
- **Still droppable:** the `APIClient` target, `Sources/APIClient/`, and `swift-openapi-urlsession`.
- **Not droppable:** `swift-openapi-generator` and `swift-openapi-runtime`.
- **The saving shrinks to almost nothing.** The 30–60 s estimate `[inferred]` was mostly the generator's host-tool prebuild. Step 0 makes that permanent, because every build that compiles `ActivityPubCore` runs the plugin. What remains is one generated client and `swift-openapi-urlsession`: a few seconds `[inferred]`.
- **Pins conflict either way.** Both rewrite `Package.resolved`, so whichever merges second re-runs Resolve Packages.

**Sequencing:** PR C lands after step 0's implementation merges. Do not land a version that removes `:36-37` before step 0, because step 0's Task 1 edits those lines in place.

- [ ] **Step 1: Gate.** `grep -n -A12 'name: "ActivityPubCore"' Package.swift` on `origin/main` must show `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")` inside the `ActivityPubCore` target. If it doesn't, step 0's implementation has not landed. Stop and report.
- [ ] **Step 2:** Delete the target and `Sources/APIClient/`. Remove the `swift-openapi-urlsession` entry. Keep the generator and runtime entries. Update the two `GettingStarted.md` lines: `openapi.yaml` stays at the root, and `integration-tests/Sources/APIClient/` still symlinks it.
- [ ] **Step 3: Pins.** Push a draft PR and add the `resolve-packages` label. Download the artifact (`gh run download <run-id> -n Package.resolved`) and commit it. Run `git diff origin/main -- Package.resolved`. Expected: `swift-openapi-urlsession` is removed and no other pin is removed. List every moved pin in the PR body.
- [ ] **Step 4: Check.** Add the `lambda-build` label. Expected:
  - green;
  - no `Compiling APIClient` line in the log;
  - "Package.resolved unchanged by the build" passes.

  The Test job is green too.
- [ ] **Step 5: Negative control.** The baseline Lambda Build log contains `Compiling APIClient Exports.swift`. Its absence in Step 4 is the change taking effect.
- [ ] **Step 6: Timing receipt.** Cold by design (`Package.resolved` changes). Compare it with the most recent cold `lambda-build` run after step 0 merged, not with the pre-step-0 baseline.
- [ ] **Step 7:** Commit `build: remove the unused root APIClient target`.

---

## Open Questions

**Q1. Multi-line `path` through `swift-build-cache-save`.**
- Task 6 relies on the composite passing a multi-line `path` straight to `actions/cache`. It does.
- Side effect: its "Fix Docker build permissions" step tests `[ -d "${{ inputs.path }}" ]` (save `action.yml:28`). That test is false for a multi-line value, so the `chown` is skipped silently.
- FAP doesn't need that `chown` after Task 6 Step 3. But the input's description ("Path to cache") doesn't say multi-line is supported.
- Question: is this an acceptable use of the shared composite?
- If not, the smallest default-preserving change to `public-actions/swift-build-cache-save` is to `chown` each line of `path` that doesn't start with `!`. A single-line `path` behaves exactly as today.

**Q2. Merge the stage integration tests into the deploy jobs, or keep the separate job?**
- **Option A, merge (Task 9).**
  - Saves about 90 s per stage deploy `[measured components]` and removes ~105 lines of duplicated YAML.
  - Costs:
    - re-running a failed integration-test step re-runs the deploy (`sam deploy`, or `update-function-code` on the fast path);
    - the workflow no longer has a separately re-runnable post-deploy test job. That departs from the separate post-deploy test job the shared testing standard describes (T5, S8).
  - Dispatching `run-integration-tests.yml` with its `environment` input set to `stage` stays as the no-deploy re-run path. It is slower, because it installs Swift on the host (`run-integration-tests.yml:67-98`); its duration is unmeasured.
- **Option B, keep the separate `integration-tests` job as it is on `bbe9fe5`.**
  - No saving, no change in re-run behaviour, and no departure from the standard. PR B is not opened, and Task 9 is dropped.
- **Evidence:**
  - In the last 40 Deploy Stage runs (2026-04-07 to 2026-10-22), the `integration-tests` job finished 24 success, 2 failure, 13 skipped and 1 cancelled.
  - It was never re-run on its own: both runs with more than one attempt had it skipped in attempt 1, and their later attempts re-ran the whole deploy `[measured: job API]`.
  - Whether the two failures were flaky is not known.
- **Recommendation:** Option A, on that evidence. Independent re-runs have not been used in six months, and a no-deploy re-run path remains. But A is a deliberate departure from the standard's job shape. If that shape is a requirement in its own right, choose B: the 90 s does not outweigh a requirement.

**Q3. PR C after step 0.** Removing `APIClient` after step 0 saves seconds, not 30–60 s. Is PR C worth its own Resolve Packages cycle and cold build, or should it ride along with the next PR that changes pins anyway?

## Deferred

- **Fixed cache key in `public-actions/swift-build-cache-save`** (no `github.sha`; save only on a miss).
  - **Revisit when:** after Tasks 5 and 6 land, the stage save step still costs ~60 s, or Task 6 Step 7's listings show entries still being evicted.
  - **Why it matters:** this is what would end the two-`.build`-entries-at-save state described under "Cache budget". Any change there must be opt-in and default-preserving, because other repositories use the composite.
- **Dependency-clone cache for the Test job and cold Lambda builds** (scope item 2). Dropped from this round; see "Cache budget". Reopen it only together with the fixed-key item above, once `gh cache list` shows steady-state headroom of at least R (Task 2) plus a margin.
  - The mechanism needs only existing composite inputs: `path: .build/repositories`, `key-prefix: swiftpm-repos`, saved from main on cold builds and restored by PRs.
  - Its first check must be that the entry is still listed after the next full-path deploy.
  - The composite's `cache-hit` output is exact-key only, and the key ends in `github.sha`, so it can't tell a caller whether anything was restored. A file probe (`.build/workspace-state.json`) would be used instead. An opt-in `matched-key` output in the composite is the additive alternative.
- **A first-party registry (GHCR) for `swift-al2023:6.3`.** Warm gain is ≤15 s per job. Its value is avoiding the 129 s cold image rebuild when the image tar is missing from the cache.

## Invariant check

- **Smallest mechanism.**
  - Existing composite inputs only (`path`, `fix-docker-permissions`).
  - One new script, only if Q2 picks the merge; it replaces the duplicated job YAML.
  - The dependency-clone cache was dropped rather than adding a second copy of `.build/repositories` under a cap that is already exceeded.
- **No new components.** No new workflow, action, cache mechanism or runner change. Task 1 is an issue.
- **Blast radius.**
  - This repository only. `public-actions` is shared, and this plan does not modify it: Q1 and Deferred describe opt-in options only.
  - Two cold stage deploys by design: the first after PR A and the first after PR C.
