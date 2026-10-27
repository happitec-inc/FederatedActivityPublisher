# CI Build-Time Reductions (Round 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the PR Test job and the stage/prod deploy jobs further, using only changes inside this repository plus one issue on the runner-image repository.

**Architecture:** Workflow and build-script edits only. Caching uses the existing `happitec-inc/public-actions` composites `swift-build-cache-restore` and `swift-build-cache-save` at `main` with their existing `path` and `key-prefix` inputs. One new script replaces the duplicated integration-test steps. No new workflow, action or cache mechanism.

**Tech Stack:** GitHub Actions on ephemeral tart Linux arm64 runners (4 CPU, 15.6 GiB), the `swift-al2023:6.3` Docker image, SwiftPM (Swift 6.3), SAM.

**Spec:** the scope settled 2026-10-27, restated in Global Constraints below. Every timing comes from a CI build review of `origin/main` at `6d02908`, recomputed from the Actions job API. Run IDs are cited where a number is used.

## Global Constraints

- **Baseline.** `origin/main` at `6d02908`. All file:line references below are to that commit.
- **Toolchain.** Swift 6.3 only. No Swift 6.4, no handler consolidation.
- **Pins.** `Package.resolved` is regenerated only by the Resolve Packages workflow (`resolve-packages` label, `.github/workflows/resolve-packages.yml`), never with a local toolchain.
- **Validation.** PR CI (the Test workflow) and the `lambda-build` label (`.github/workflows/lambda-build.yml`). Deploy-workflow changes are validated by the first post-merge run; fix forward. Never use, clone, boot or SSH a runner VM or runner image. Never run `aws` or `sam deploy` locally.
- **Caches.** Only `happitec-inc/public-actions/swift-build-cache-restore@main` and `.../swift-build-cache-save@main` for Swift build state. Do not add `actions/cache` steps for Swift state and do not write a new cache mechanism. The existing `actions/cache@v5` steps for `/tmp/docker-image.tar` stay as they are.
- **Out of scope.** Promoting stage zips to prod. Moving `detect` to a hosted runner. Runner-image changes (Task 1 only files an issue).
- **Public repository.** Commit messages, PR bodies and run titles are short and about the code. No closing keywords; reference issues as "Refs FederatedActivityPublisher#N".
- **Evidence grade.** Every saving below is tagged `[measured]` (from a CI log or the job API), `[inferred]` (mechanism known, size not measured) or `[unverified]` (premise not yet checked; the named task step measures it).
- **Negative control.** A task's check counts only after its control has been seen to fail, or the PR description says why no failing control exists.

## Review Focus

1. **Cache `path` drift.** `actions/cache` derives an entry's version from its `path` list, so a restore whose `path` differs from the save's never matches, and nothing reports it: every run is silently cold. Task 9 changes `path` at six call sites. Its Step 4 checks all of them by grep, and Step 6 checks the post-merge restore log.
2. **Root-owned files at save time.** With a multi-line `path`, the save composite's `chown` step never runs (see Open Questions, Q1). The fast path builds as root (`deploy-stage.yml:146-150`, no `--user`). Task 9 Step 3 moves its `chown` into a separate `if: always()` step.
3. **Integration-test failure semantics.** After Task 11, a failing integration test turns the deploy job red after the deploy has already happened. Before, the deploy job stayed green and a separate job went red. Task 11 Step 5 records this in the PR body. The deploy itself is not rolled back in either case.
4. **Bearer token in logs.** The token currently travels through `GITHUB_OUTPUT` (`deploy-stage.yml:443-453`). The new script keeps it in a shell variable and masks it (Task 11 Step 1). Its control is a grep of the run log.
5. **Repository cache-size cap.** The repository has a 10 GB Actions cache cap. Today there is one 5.38 GiB entry (`gh cache list`, 2026-10-27). Task 10 adds a dependency-clone entry of unmeasured size. Task 10 Step 6 records its size and the total.

---

## PR grouping

| PR | Tasks | Validated by |
|---|---|---|
| — | 1 (runner-image issue), 2 (measure the pre-planning gap) | no merge |
| PR A: Test job, prod cache, build script | 3, 4, 5, 6, 7, 8 | Test workflow; `lambda-build` label |
| PR B: caches and job merge | 9, 10, 11; then 12 (measurement) after merge | `lambda-build` label; the first post-merge stage deploy |
| PR C: dead `APIClient` target | 13, sequenced after reply-threading step 0 (see Task 13) | `resolve-packages`, then `lambda-build` |

---

### Task 1: Issue on the runner image for preinstalled Swift 6.3

**Files:** none in this repository.

- [ ] **Step 1: File an issue on `happitec-inc/TartRunnerKit`.** Title: `Linux runner image: preinstall Swift 6.3 and the Swift build apt packages`. The body states these facts and no proposed implementation:
  - The FederatedActivityPublisher Test job (`.github/workflows/test.yml`) spends 35–49 s on every run installing these on a fresh VM `[measured]`:
    - "Install Swift dependencies" (`test.yml:31-36`): 16–25 s.
    - "Install Swift" (`test.yml:38-51`): 18–24 s. The `swift --version | grep -q "6.3"` check fails on the fresh VM, so the tarball downloads every time.
    - Run IDs: 39729400471, 39717290454, 39708039693, 39822228060.
  - The packages are `binutils gcc g++ libc6-dev libcurl4-openssl-dev libssl-dev libxml2-dev pkg-config` (`test.yml:34`).
  - The toolchain is `swift-6.3-RELEASE-ubuntu24.04-aarch64.tar.gz` (`test.yml:45`), extracted with `--strip-components=2` into `/usr/local`.
  - The job also replaces `/usr/include/unicode` with Swift's bundled ICU headers (`test.yml:53-62`). An image that preinstalls Swift needs the same header state, or the job keeps doing that step.
  - `.github/workflows/run-integration-tests.yml:62-93` repeats the same three steps.
- [ ] **Step 2: Negative control.** None applies to filing an issue. Record the issue URL in PR A's description.

---

### Task 2: Measure the ~46 s gap before "Planning build"

**Files:** a throwaway branch only; nothing merges.

The gap appears in three logs `[measured]`:
- cold stage, 02:28:41–02:29:32 (run 39710962177);
- warm stage, 03:50:51–03:51:37 (run 39718739545);
- Test, 05:48:11–05:48:57 (run 39729400471).

Whether it is manifest/graph load or plugin evaluation is unknown.

- [ ] **Step 1:** `git switch -c measure/swift-build-verbose origin/main`. In `scripts/build-all-lambdas.sh:106`, add `-v` to `BUILD_ARGS`. Commit and push the branch. Do not open a PR.
- [ ] **Step 2:** `gh workflow run lambda-build.yml --ref measure/swift-build-verbose`. The workflow has `workflow_dispatch` (`lambda-build.yml:13`) and is on the default branch.
- [ ] **Step 3:** `gh run view <run-id> --log > verbose.log`. Find the last line before `Planning build` and the line before it. Record, with timestamps:
  - each command SwiftPM ran inside the gap (`swiftc` manifest compiles, plugin compiles and runs, `git` invocations);
  - the duration of each.
- [ ] **Step 4:** Delete the remote branch. Post the table as a comment on PR A, so the receipt sits next to the work it informs. No fix is planned here.
- **Negative control:** the same window in the non-verbose run 39718739545 shows no per-command lines. If the verbose log also shows nothing inside the gap, `-v` did not reach the build. Check `BUILD_ARGS` before drawing any conclusion.

---

### Task 3 (PR A): Delete the zero-test root `IntegrationTests` step

Refs FederatedActivityPublisher#296.

**Files:**
- Modify: `.github/workflows/test.yml:70-72` (delete the step "Run integration tests (non-network)")

The step runs `swift test --filter IntegrationTests` with `continue-on-error: true`. The root package has only `Tests/ActivityPubCoreTests`; the integration tests live in `integration-tests/Package.swift`. Its log ends with `warning: No matching test cases were run` and `Test run with 0 tests in 0 suites`.

- [ ] **Step 1:** Delete `test.yml:70-72`.
- [ ] **Step 2: Negative control, before the edit.** In the log of the "Run integration tests (non-network)" step on PR A's first push, confirm `Test run with 0 tests`. That is the evidence that deleting it loses nothing. If any count other than 0 appears, stop: a root integration test exists and this task is wrong.
- [ ] **Step 3: Timing receipt.** The Test job on the next push drops by 78–129 s `[measured]` against the four baseline runs. Record the job duration.
- [ ] **Step 4:** Commit `ci: drop the root integration-test step that runs no tests`.

---

### Task 4 (PR A): Test job builds only the test product

**Files:**
- Modify: `.github/workflows/test.yml:64-65` ("Run unit tests")

Today `swift test --filter ActivityPubCoreTests` builds every product: 19 debug handler links, `ActivityProvisioner` and `APIClient`. Handler links appear at 05:47:13–05:47:23 in run 39729400471, against 0.5 s of test execution. Expected saving: 10–25 s `[inferred]`.

- [ ] **Step 1:** Replace the step with two steps:
  - "Build unit tests": `swift build --product federated-activity-publisherPackageTests`. The package name is `federated-activity-publisher` (`Package.swift:6`). SwiftPM's synthesized test product name is `<name>PackageTests` `[unverified]`; Step 2 measures it.
  - "Run unit tests": `swift test --skip-build --filter ActivityPubCoreTests`. `--skip-build` is listed by `swift test --help`. That was checked against a local Swift 6.4.2 help text; the CI 6.3 toolchain is exercised by Step 2.
- [ ] **Step 2: Check.** On PR CI:
  - "Build unit tests" succeeds;
  - its log contains no `Linking` line for any `*Handler`;
  - "Run unit tests" reports the same `Test run with N tests` count as the last baseline run's "Run unit tests" step.

  If SwiftPM rejects the product name, stop and report it. Drop this task from PR A rather than substituting another flag.
- [ ] **Step 3: Negative control.** Push a throwaway commit that adds `#expect(Bool(false))` to one existing test in `Tests/ActivityPubCoreTests`. "Run unit tests" must go red, which proves `--skip-build` ran the freshly built bundle. Revert with a new commit.
- [ ] **Step 4: Timing receipt.** Record the combined duration of the two steps against the baseline "Run unit tests" (308–463 s).
- [ ] **Step 5:** Commit `ci: build only the test product before swift test`.

---

### Task 5 (PR A): Prod restores the build cache but does not save it

Refs FederatedActivityPublisher#297.

**Files:**
- Modify: `.github/workflows/deploy-prod.yml:74-78` (delete the step "Save Swift build cache")

Prod run 39721690715 spent 58 s saving `[measured]`. A release-triggered run saves the entry under the tag's ref. GitHub's documented cache scoping lets main read only main's and the default branch's entries, so that entry has no later reader `[inferred, from GitHub's docs, not tested]`. `gh cache list` on 2026-10-27 shows a single 5.38 GiB entry, created 2026-10-22T04:24:39Z, which matches the prod run. The stage entry saved at 03:53 the same morning is gone.

- [ ] **Step 1:** Delete `deploy-prod.yml:74-78`. Keep "Restore Swift build cache" (`:63-66`) unchanged.
- [ ] **Step 2: Check (post-release, so it lands after merge).** After the next prod release:
  - `gh cache list` shows no new entry created during that prod run;
  - the stage deploy that follows logs a restore from a main-scoped key in "Restore Swift build cache".
- [ ] **Step 3: Negative control.** The current state is the failing control. The entry list on 2026-10-27 holds only the prod-run entry. Record that list in the PR description before merge.
- [ ] **Step 4: Timing receipt.** The prod job loses the 58 s save step `[measured]`.
- [ ] **Step 5:** Commit `ci: prod restores the Swift build cache without saving it`.

---

### Task 6 (PR A): Drop the separate `swift package resolve`

**Files:**
- Modify: `scripts/build-all-lambdas.sh:95-100` (delete the "resolve" phase), `:9-11` (header comment: drop item 2 and renumber)

`SWIFTPM_FLAGS` (`:37`) already includes `--force-resolved-versions`, and the build at `:106-107` passes `"${SWIFTPM_FLAGS[@]}"`. So `swift build` resolves against the committed `Package.resolved` itself. `swift build --help` lists `--force-resolved-versions`, checked against a local 6.4.2 help text. The phase costs 9 s warm and 127 s cold `[measured]`. The saving is at most the duplicated work `[inferred]`: on a cold build most of the 127 s is the clone, which moves into the build phase rather than disappearing.

- [ ] **Step 1:** Delete the phase. Keep `SWIFTPM_FLAGS` unchanged.
- [ ] **Step 2: Check.** Add the `lambda-build` label. Expected:
  - green;
  - "Package.resolved unchanged by the build" (`lambda-build.yml:61-62`) passes;
  - the "Phase timings" table no longer lists `resolve`.
- [ ] **Step 3: Negative control.** Push a throwaway commit that deletes `Package.resolved`, and run the label again. The build phase must fail because no resolved file exists while automatic resolution is disabled. This proves the build still enforces the pins with no resolve phase. Revert with a new commit.
- [ ] **Step 4: Timing receipt.** Total from "Phase timings", warm, against the baseline 120 s step (resolve 9 s, build 98 s, zip 11 s; run 39718739545).
- [ ] **Step 5:** Commit `build: let swift build resolve against the pins`.

---

### Task 7 (PR A): `.build` composition receipt

**Files:**
- Modify: `.github/workflows/lambda-build.yml`: add a step after "Verify Lambda zips" (`:64-65`)

This measures what Task 9 removes. The 19 zips total 674,325,891 bytes `[measured]`. Their share of the 5.38 GiB entry is not measured.

- [ ] **Step 1:** Add the step "Build cache composition" with `if: always()`. It runs:
  - `du -sh .build/* .build/plugins/* .build/lambda-staging .build/plugins/AWSLambdaPackager 2>/dev/null | sort -h`;
  - `ls -la .build/workspace-state.json`.
- [ ] **Step 2: Check.** The `lambda-build` run prints sizes for:
  - `.build/repositories`;
  - `.build/checkouts`;
  - `.build/release` (or the `aarch64-unknown-linux-gnu` directory it links to);
  - `.build/lambda-staging`;
  - `.build/plugins/AWSLambdaPackager`.

  It also shows `.build/workspace-state.json` exists (Task 10 uses that file as its cold-cache signal). Copy the output into PR A's description.
- [ ] **Step 3: Negative control.** In the same run, the "Restore Swift build cache" log reports the restored archive size. The sum of the `du` lines must be within 10% of it. A large mismatch means `du` measured something other than the restored tree.
- [ ] **Step 4:** Commit `ci: print the build cache's composition in Lambda Build`.

---

### Task 8 (PR A): Byte-reproducible zips

**Files:**
- Modify: `scripts/build-all-lambdas.sh:120-131` (`zip_one`), `:155-171` ("check outputs" phase)

Today `cp` at `:126` gives `bootstrap` a fresh mtime, and `zip -X` (`:130`) still stores mtimes. Identical binaries therefore produce different zips. `sam package` re-uploads all 19 zips (~674 MB), and CloudFormation sees 19 changed code keys. Run 39718739545 changed only `.github` files and still spent 21 s in `sam package` and 58 s in `sam deploy` `[measured]`.

- [ ] **Step 1: `zip_one`.** After the existing copies and `chmod`:
  - set every staged file to one fixed time: `touch -h -d @315532800` on `bootstrap`, `lib/libcrypto.so.3` and `lib/libssl.so.3`. That is 1980-01-01T00:00:00Z, the earliest time a zip timestamp can hold.
  - zip with a fixed timezone, no directory entries and an explicit file order: `TZ=UTC zip -q -X -D "$out_zip" bootstrap lib/libcrypto.so.3 lib/libssl.so.3`.

  `-D` drops the `lib/` directory entry. `scripts/verify-lambda-zips.sh:74` unzips and checks `lib/<name>` (`:98-100`), so it still covers the layout.
- [ ] **Step 2: Hashes in "check outputs".** For each handler, print the zip's `sha256sum` and the `sha256sum` of `unzip -p "$z" bootstrap`, next to the existing size. Both tools are in the image: `verify-lambda-zips.sh` already relies on `unzip`.
- [ ] **Step 3: Reproducibility check.** On PR A's head SHA, run `gh workflow run lambda-build.yml --ref <PR A branch>` twice, starting the second only after the first finishes. Both dispatches share one concurrency group with `cancel-in-progress: true` (`lambda-build.yml:17-19`), so a second dispatch cancels the first. Diff the two hash lists.
  - **Zip hashes identical:** the change works. Record it.
  - **Zip hashes differ, `bootstrap` hashes identical:** packaging is still non-deterministic. Fix it before merge.
  - **`bootstrap` hashes differ:** the Swift binaries are not reproducible across two builds of the same source. Each run recompiles project sources, because checkout mtimes are fresh. Fixed zip mtimes then cannot give identical zips, and the Step 5 saving does not occur. Keep Steps 1–2 (harmless, and the hashes stay useful), record which handlers differ, and stop there. Linker determinism is not in this plan.
- [ ] **Step 4: Negative control.** The baseline is the failing control. Before Step 1, run the label twice on PR A's first push, which carries Step 2's hash printing only. Expect differing zip hashes even where the `bootstrap` hashes match. If they already match, mtimes were not the cause, and this task's premise is wrong.
- [ ] **Step 5: Timing receipt (post-merge).** On the next stage deploy whose change set does not touch Swift sources:
  - `sam package` should log a skip for each unchanged artifact instead of an upload `[unverified: exact SAM wording]`;
  - its step time should fall below 21 s;
  - the `sam deploy` change set should not list the 19 functions' code as changed.
  - Saving: 20–50 s `[inferred]`.
- [ ] **Step 6:** Commit `build: reproducible Lambda zips and per-zip hashes`.

---

### Task 9 (PR B): Slim the `.build` cache

**Files:**
- Modify: `.github/workflows/deploy-stage.yml:136-139`, `:154-158` (fast-deploy restore/save), `:289-292`, `:300-304` (build restore/save)
- Modify: `.github/workflows/deploy-prod.yml:63-66` (restore; the save is gone after Task 5)
- Modify: `.github/workflows/lambda-build.yml:53-56` (restore)

**Interfaces:**
- Produces: the cache `path` value used by every Swift build cache call site (exact text, one entry per line):
  ```
  .build
  !.build/lambda-staging
  !.build/plugins/AWSLambdaPackager
  ```

Both excluded paths are rebuilt every run:
- `build-all-lambdas.sh:118` runs `rm -rf "$STAGING_DIR" "$OUTPUT_BASE"` before staging. `STAGING_DIR` is `.build/lambda-staging` (`:31`) and `OUTPUT_BASE` is `.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager` (`:30`). `zip_one` recreates both with `mkdir -p` (`:125`).
- `build-selective.sh` recreates them per target with `mkdir -p` (`:100`, `:105`).
- The fast path's zip-bundling and update steps (`deploy-stage.yml:163-180`, `:204-242`) read only the targets it just built.

Only `.build/plugins/AWSLambdaPackager` is excluded. Other `.build/plugins/*` directories hold plugin build state and stay.

- [ ] **Step 1: Gate on Task 7's numbers.** If `.build/lambda-staging` plus `.build/plugins/AWSLambdaPackager` is under 500 MB of the restored size, stop. Report that the saving is below the review's estimate, and do not change six call sites for it.
- [ ] **Step 2:** At each of the six call sites, pass the `path` value above. `swift-build-cache-restore` and `swift-build-cache-save` forward `path` verbatim to `actions/cache/restore@v5` and `actions/cache/save@v5` (`path: ${{ inputs.path }}`, restore `action.yml:29`, save `action.yml:35`). `actions/cache` documents multi-line `path` with `!` exclusions. See Open Questions, Q1 for the save composite's `chown` step.
- [ ] **Step 3: Fast-path ownership.** In fast-deploy, move `sudo chown -R $(id -u):$(id -g) .build` out of "Build changed targets in Docker" (`deploy-stage.yml:152`) into its own step with `if: always()`, placed before "Save Swift build cache". Pass `fix-docker-permissions: 'false'` to every save call. With the multi-line `path`, the composite's `[ -d "${{ inputs.path }}" ]` test is false and its `chown` is skipped anyway; the explicit input makes that visible. The full-path build runs as the runner uid (`scripts/in-build-image.sh:23`), and `lambda-build.yml:67-69` asserts no root-owned files.
- [ ] **Step 4: Check.** `grep -n -A3 'swift-build-cache-' .github/workflows/*.yml` shows the identical three-line `path` under all six uses.
- [ ] **Step 5: Expected on PR B's `lambda-build` run.** The restore misses: changing `path` changes the cache version, so main's existing entry does not match. The build is cold (~393 s build step, run 39710962177). Say this in the PR body so a reviewer does not read it as a regression.
- [ ] **Step 6: Post-merge check.**
  - The first stage deploy saves the new entry, cold.
  - The second restores it.
  - `gh cache list` shows the new entry's size; record it against 5.38 GiB.
  - **Negative control:** the second deploy's restore step must log a key match, not "Cache not found". "Cache not found" means a `path` mismatch somewhere (Review Focus 1). If the second deploy is also cold, that is the failure signal.
- [ ] **Step 7: Timing receipt.** Restore plus save against 75 s + 66 s (run 39718739545). Expected saving: 35–55 s `[inferred]`, scaled by Task 7's measured share.
- [ ] **Step 8:** Commit `ci: keep never-reused Lambda staging out of the build cache`.

---

### Task 10 (PR B): Cache SwiftPM dependency clones

**Files:**
- Modify: `.github/workflows/test.yml`: add a restore step after "Checkout" (`:26-29`); add `--disable-dependency-cache` to the swift commands in "Build unit tests" and "Run unit tests" (Task 4)
- Modify: `.github/workflows/deploy-stage.yml`: build job, after "Restore Swift build cache" (`:289-292`), and after "Save Swift build cache" (`:300-304`)
- Modify: `.github/workflows/lambda-build.yml`: after "Restore Swift build cache" (`:53-56`)

**Interfaces:**
- Consumes: Task 9's restore step, which runs first in the same job.
- Produces: one cache family. `key-prefix: swiftpm-repos`, `path: .build/repositories` (single line).

Dependency acquisition costs:
- Test run 39729400471: ~160 s of the 308 s unit-test step. The aws-sdk-swift fetch alone is 110.58 s, and creating working copies is ~41 s `[measured]`.
- Cold stage resolve (run 39710962177): 127 s `[measured]`.

The Test job has no cache at all. This task caches only the bare clones in `.build/repositories`. The 41 s of working-copy creation remains. Checkouts and `workspace-state.json` are not shared between the Docker build (`/workspace`) and the host Test job (the runner's checkout path).

**Feasibility with the existing composites: yes, with existing inputs only.**
- `path: .build/repositories` and `key-prefix: swiftpm-repos` produce keys `swiftpm-repos-<hashFiles('Package.swift')>-<sha>`, with restore-keys `swiftpm-repos-<hash>-` then `swiftpm-repos-` (restore `action.yml:30-33`). A restore therefore takes the most recent clone set and SwiftPM fetches whatever is newer.
- **Gap, and how this task avoids it:** the composite's `cache-hit` output is exact-key only, and the key always ends in `github.sha`. So `cache-hit` is never true on a new push and cannot tell a caller whether anything was restored. This task uses a file probe instead (Step 1). See Open Questions, Q2.

- [ ] **Step 1: Cold-cache probe (deploy-stage build job and lambda-build).** Right after the `.build` restore, add a step with `id: cold`:
  `if [ -f .build/workspace-state.json ]; then echo cold=false; else echo cold=true; fi >> "$GITHUB_OUTPUT"`.
  Task 7 Step 2 confirms the file exists in a warm `.build`.
- [ ] **Step 2: Restore clones on a cold build.** In both jobs, add a restore step: `swift-build-cache-restore` with `path: .build/repositories`, `key-prefix: swiftpm-repos` and `if: steps.cold.outputs.cold == 'true'`. A warm `.build` already contains `.build/repositories`, because `build-all-lambdas.sh:37` passes `--disable-dependency-cache`.
- [ ] **Step 3: Save clones from main on a cold build.** In the deploy-stage build job only, add a step after "Save Swift build cache": `swift-build-cache-save` with the same `path` and `key-prefix` and `if: steps.cold.outputs.cold == 'true'`. Pull requests never save this entry; the same restore-only rule as `lambda-build.yml:47-48`. Pull requests can read main-scoped entries. The first stage deploy after PR B merges is cold (Task 9 Step 5), so it seeds the entry.
- [ ] **Step 4: Test job.** After "Checkout", add the same restore step without a condition: the Test job always starts from an empty `.build`, because "Clean workspace" (`test.yml:20-24`) removes it. Pass `--disable-dependency-cache` to both swift commands so SwiftPM uses `.build/repositories` and not the per-user shared cache. Leave the schema-conformance step (`test.yml:67-68`, `integration-tests` package) unchanged.
- [ ] **Step 5: Premise check `[unverified]`.** Two premises:
  - SwiftPM reuses bare clones created by the Docker build on the host;
  - with an existing clone, SwiftPM updates it instead of cloning again.

  Measure both on the first PR push after the entry exists. In the "Build unit tests" log, the aws-sdk-swift line must not show a ~110 s fetch, and the step must not spend ~160 s before the first `Compiling` line. If either premise fails, revert Step 4 and report it. The cold-deploy half (Steps 1–3) can stand alone.
- [ ] **Step 6: Size.** After seeding, record the `swiftpm-repos-*` entry's size and the total of `gh cache list` (Review Focus 5). If the total exceeds 10 GB, stop and report before more entries pile up.
- [ ] **Step 7: Negative control.** The baseline Test run 39729400471 is the failing control: 110.58 s fetching aws-sdk-swift. A second control: re-run the Test job with the restore step's `key-prefix` temporarily set to `swiftpm-repos-none`, which matches nothing. The ~110 s fetch must reappear. Revert.
- [ ] **Step 8: Timing receipt.**
  - Test job: dependency acquisition before the first `Compiling` line, against ~160 s. Saving up to ~120 s, net of the restore, which is unmeasured `[inferred]`.
  - Cold deploy: the build phase's fetch lines, against 127 s.
- [ ] **Step 9:** Commit `ci: cache SwiftPM dependency clones for Test and cold Lambda builds`.

---

### Task 11 (PR B): Run integration tests inside the deploy jobs

**Files:**
- Create: `scripts/run-stage-integration-tests.sh`
- Modify: `.github/workflows/deploy-stage.yml`: delete the `integration-tests` job (`:369-485`); add a final step to `fast-deploy` (after `:204-242`) and to `build` (after `:361-367`)

**Interfaces:**
- Produces: `scripts/run-stage-integration-tests.sh`.
  - No arguments.
  - Reads `AWS_REGION` and `TEST_HANDLE_DOMAIN` from the environment.
  - Expects AWS credentials configured, `aws` on `PATH`, and the image `swift-al2023:6.3` loaded.
  - Exits 0 on pass and 1 on fail.

On the warm full path:
- The `integration-tests` job started 57 s after `build` finished.
- It spent 16 s restoring and 17 s loading the image before a 42 s test `[measured]` (run 39718739545).

Both deploy jobs already have the image loaded and AWS configured:
- fast-deploy: `:113-128`, `:182-202`;
- build: `:272-279`, `:309-314`; `aws` is used at `:348`.

- [ ] **Step 1: Write the script.** Same behaviour as `deploy-stage.yml:429-485`:
  - reads `ApiEndpoint` and `ClientApiUrl` from stack `activity-app-stage`;
  - reads `/activity/stage/keys/client-token` from SSM and takes field 2 after `cut -d: -f2`. The value is masked with `echo "::add-mask::$BEARER"` before any other output and is never written to `GITHUB_OUTPUT`;
  - runs `swift test` in `swift-al2023:6.3` with the repository mounted at `/workspace` and `-w /workspace/integration-tests`, passing the four `TEST_*` variables;
  - keeps the pass/fail parsing from `:478-485`, including the FoundationNetworking teardown case.

  Two differences from today:
  - `docker run` adds `--user "$(id -u):$(id -g)" -e HOME=/tmp`, as `scripts/in-build-image.sh:22-27` does, so `integration-tests/.build` is not root-owned.
  - The tests now compile against the substituted `openapi.yaml`, because both jobs run "Substitute domain variables". The integration tests pass `serverURL` from `TEST_API_URL` and never use the generated `Servers` values (`grep -rn "Servers\." integration-tests/Tests` finds nothing), so this does not change what they hit.
- [ ] **Step 2:** In both jobs, add the final step "Run integration tests" with `env: TEST_HANDLE_DOMAIN: stage.${{ vars.HANDLE_DOMAIN }}`, running `bash scripts/run-stage-integration-tests.sh`.
- [ ] **Step 3:** Delete the `integration-tests` job (`:369-485`). Nothing else `needs` it.
- [ ] **Step 4: Negative control (post-merge, full path).** The first stage deploy after merge must show:
  - the "Run integration tests" step;
  - `Test Suite` lines in its log;
  - only two jobs (`detect`, `build`).

  The log must contain no `bearer=` line and no `GITHUB_OUTPUT` write of the token.

  For the failing control, do not dispatch `deploy-stage.yml` from a branch: that deploys the branch to stage. Instead, before merge, run the script locally with stub `aws` and `docker` executables first on `PATH`:
  - the `aws` stub prints placeholder URLs and token;
  - the `docker` stub prints a transcript with a failing `Test Suite ... failed` line.

  The script must exit 1. With a `docker` stub that prints `passed with 0 issues`, it must exit 0. No real AWS call is made.
- [ ] **Step 5: PR body.** State the changed failure semantics (Review Focus 3).
- [ ] **Step 6: Timing receipt.** Whole-workflow wall time on a warm full path, against 10m10s. Expected about −90 s `[measured]` components.
- [ ] **Step 7:** Commit `ci: run stage integration tests in the deploy job`.

---

### Task 12 (after PR B): Measure one fast-path deploy on tart

**Files:** none.

No fast-path run has happened since the tart move (the last 25 stage runs were full or skipped). The fast path also carries Task 9's ownership change and Task 11's test step, which have no other validation.

- [ ] **Step 1:** At the first stage deploy whose `detect` output is `path=fast` (a merge touching only `Sources/<Handler>/`), record:
  - per-target `Completed: <T> (Ns)` lines from `build-selective.sh:109`;
  - the restore, build, save and test step times;
  - whether each `swift build --product` invocation (`build-selective.sh:92`) pays the Task 2 gap.
- [ ] **Step 2:** Comment the table on PR B. No change is planned from it here.
- **Negative control:** the run's `detect` log must say `Fast path:`. A full-path run does not count.

---

### Task 13 (PR C): Remove the dead root `APIClient` target

**Files:**
- Delete: `Sources/APIClient/` (`Exports.swift`, `openapi-generator-config.yaml`, the `openapi.yaml` symlink)
- Modify: `Package.swift:239-249` (target), `:38` (`swift-openapi-urlsession` entry); `:36-37` per the sequencing below
- Modify: `Sources/ActivityPubCore/Documentation.docc/GettingStarted.md:50`, `:57` (tree lines naming `Sources/APIClient/`)
- Modify: `Package.resolved` (from the workflow artifact only)
- Do not touch: `integration-tests/`, which keeps its own `APIClient`

**Nothing at root depends on it (verified at `6d02908`).**
- `grep -rn APIClient` outside `integration-tests/`, `.git` and `docs/superpowers/` finds:
  - `Package.swift:241`;
  - `scripts/detect-changed-targets.sh:114` (a skip branch);
  - `scripts/test-detect-changed-targets.sh:59-62` (its test);
  - `GettingStarted.md:50`, `:57`.
- No target lists `"APIClient"` as a dependency.
- `swift-openapi-runtime`, `-urlsession` and `-generator` are named only by the `APIClient` target (`Package.swift:243-247`).
- Leave the two `detect-changed-targets` lines in place. With the directory gone they never match, and removing them would turn a hypothetical future `Sources/APIClient/` change into a fast-path build of a non-Lambda product.

**Interaction with reply-threading step 0 (FederatedActivityPublisher#294, approved, not merged). This conflicts.** Step 0's Task 1:
- **raises**, not removes, `swift-openapi-generator` to `from: "1.11.1"` and `swift-openapi-runtime` to `from: "1.11.0"`, editing `Package.swift:36-37` in place;
- adds `swift-openapi-async-http-client` and five other entries;
- adds `OpenAPIRuntime` and `OpenAPIAsyncHTTPClient` to `ActivityPubCore`.

Its Task 4 puts `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")` on `ActivityPubCore`. Once step 0 lands:
- **Still droppable:** the `APIClient` target, `Sources/APIClient/`, and `swift-openapi-urlsession` (step 0 uses the AsyncHTTPClient transport, not URLSession).
- **Not droppable:** `swift-openapi-generator` and `swift-openapi-runtime`. Step 0 needs both.
- **Saving shrinks to almost nothing.** The review attributed this item's 30–60 s `[inferred]` mainly to prebuilding the generator's host tools (OpenAPIKit, Yams). After step 0, every build that compiles `ActivityPubCore` runs that plugin, so that cost comes back permanently. What remains is compiling one generated client and cloning and compiling `swift-openapi-urlsession`: a few seconds `[inferred]`.
- **Pins conflict either way.** Both changes rewrite `Package.resolved`, so whichever merges second re-runs Resolve Packages on a rebased branch.

**Sequencing:** land PR C after step 0's implementation merges, scoped to the target, the directory, `:38` and the docs lines. Do not land a version that removes `:36-37` before step 0: step 0's Task 1 edits those lines in place and its plan would no longer apply.

- [ ] **Step 1: Gate.** Confirm step 0's implementation has merged (`gh pr list --state merged --search "fetch hardening"`). If it has not, stop and report. Do not start PR C on the pre-step-0 `Package.swift`.
- [ ] **Step 2:** Delete the target and `Sources/APIClient/`. Remove the `swift-openapi-urlsession` package entry. Keep the generator and runtime entries. Update the two `GettingStarted.md` lines: `openapi.yaml` stays at the root and `integration-tests/Sources/APIClient/` still symlinks it.
- [ ] **Step 3: Pins.** Push a draft PR and add the `resolve-packages` label. Download the artifact (`gh run download <run-id> -n Package.resolved`) and commit it. Run `git diff origin/main -- Package.resolved`. Expected: `swift-openapi-urlsession` is removed and no other pin is removed. List every moved pin in the PR body.
- [ ] **Step 4: Check.** Add the `lambda-build` label. Expected:
  - green;
  - the log has no `Compiling APIClient` line;
  - "Package.resolved unchanged by the build" passes.

  The Test job is green.
- [ ] **Step 5: Negative control.** In the baseline Lambda Build log, `Compiling APIClient Exports.swift` is present. Its absence in Step 4 is the change taking effect.
- [ ] **Step 6: Timing receipt.** This PR changes `Package.resolved`, so its `lambda-build` run is cold. Compare it with the cold baseline: build phase 251 s (run 39710962177, pre-step-0). Report it as a cold-to-cold comparison only, and note that step 0 changed the baseline in between.
- [ ] **Step 7:** Commit `build: remove the unused root APIClient target`.

---

## Open Questions

**Q1. Multi-line `path` through `swift-build-cache-save`.**
- Task 9 relies on the composite passing a multi-line `path` straight to `actions/cache`. It does: `path: ${{ inputs.path }}`.
- Side effect: the composite's "Fix Docker build permissions" step tests `[ -d "${{ inputs.path }}" ]`, which is false for a multi-line value, so the `chown` is skipped silently.
- FAP does not need that `chown` after Task 9 Step 3. But the input's description ("Path to cache") does not say multi-line is supported.
- Question: is this an acceptable use of the shared composite?
- If not, the smallest default-preserving change to `public-actions/swift-build-cache-save`: in that step, `chown` each line of `path` that does not start with `!`. A single-line `path` behaves exactly as today. No other consumer changes.

**Q2. No "was anything restored" signal from `swift-build-cache-restore`.**
- `cache-hit` is exact-key only, and the key always ends in `github.sha`, so in practice it is never true on a new SHA.
- Task 10 works around this inside FAP with a file probe, not with any change to the composite.
- Smallest additive public-actions change, if wanted later: an opt-in `matched-key` output mapped from `actions/cache/restore`'s `cache-matched-key`. Existing callers would be unaffected.

**Q3. Cache-cap pressure.** Task 10 adds an entry family of unmeasured size next to the ~5.4 GB build entry and the ~1.2 GB Docker image entry. Task 10 Step 6 measures it.

**Q4. PR C after step 0.** Removing `APIClient` after step 0 saves seconds, not the review's 30–60 s. Is PR C still worth a Resolve Packages cycle and a cold build on its own, or should it ride along with the next PR that changes pins anyway?

## Deferred

- **Fixed cache key in `public-actions/swift-build-cache-save`** (no `github.sha`, save only on a miss). Revisit only if, after Tasks 5 and 9 land, the stage save step still costs ~60 s. Any change there must be opt-in and default-preserving, because other repositories use the composite.
- **A first-party registry (GHCR) for `swift-al2023:6.3`.** Warm gain is ≤15 s per job. Its value is avoiding the 129 s cold image rebuild when the Actions cache evicts the image tar.

## Invariant check

- **Smallest mechanism.**
  - Existing composite inputs only (`path`, `key-prefix`, `fix-docker-permissions`).
  - One new script, which replaces ~115 lines of duplicated job YAML.
  - No change to `public-actions`; Q1 and Q2 describe changes there only as options.
- **No new components.** No new workflow, action, cache mechanism or runner change. Task 1 is an issue, not a change.
- **Blast radius.**
  - The PRs change this repository only.
  - `public-actions` is shared, and this plan does not modify it.
  - The first stage deploy after PR B and the `lambda-build` run on PR C are cold by design (Task 9 Step 5, Task 13 Step 6).
