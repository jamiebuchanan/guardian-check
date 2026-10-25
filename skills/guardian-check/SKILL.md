---
name: guardian-check
description: Deploy regression guardian. Runs typecheck, the production build and unit tests against the current (or a specified) Node project, loops to fix build failures, and diagnoses flaky tests instead of retrying past them. Use when the user asks to "guardian check", "pre-flight the build", "verify before push", "check the build" or "test for regressions", or when a host such as Vercel or Railway failed a production build that the local typecheck missed. Works on any Node project with a tsconfig.json, a build script and a test:unit or test script.
argument-hint: [project path]
license: MIT
---

# guardian-check

The deploy regression guardian. It catches the failure class where the workspace
typecheck passes (`tsc --noEmit`) but the production build (`next build` or
similar) fails: TS2589 "type instantiation is excessively deep" and friends. It
also tells intermittent test failures apart from genuine breaks, and sends a
diagnostic agent after the root cause of a flake rather than just retrying.

## How it is structured

Two layers:

- **Detection** (`lib/run-checks.mjs`): a Node CLI. Runs typecheck, then build, then unit tests, retries a failed test run once to detect flakes, and writes a structured verdict to `working/verdict.json`. Stateless. Does NOT edit source files.
- **Orchestration** (this file): Claude reads the verdict and runs the fix loop or the flake-diagnosis agent. It lives in the conversation because it needs the edit tool and the ability to spawn an agent, which a CLI does not have.

Exit codes of the CLI: `0` pass (a flake that passes on retry counts as a pass, with `flaky: true`), `1` a step failed, `2` setup problem (no `package.json`, nothing to check or every step skipped, bad flag).

## Step-by-step autonomous loop

When invoked, run the loop below **without asking permission between attempts**: invoking the skill is the authorisation. Report progress with your task or todo tool (TaskCreate/TaskUpdate, or TodoWrite on older versions) so the user can follow a long run. Plain text updates are fine if you have neither.

1. **Resolve the project path.** If the user passed an argument, use it as `--project`. Otherwise use the current working directory. Check that `package.json` exists there.

2. **Detection (attempt 1).**
   - Run: `node ~/.claude/skills/guardian-check/lib/run-checks.mjs --project <path>` (omit `--project` when the current directory is the project). If the skill is installed at project level, use `.claude/skills/guardian-check/lib/run-checks.mjs` instead.
   - Exit 0 and `verdict.flaky === false`: report "Guardian passed: typecheck, build and tests are green" and finish.
   - Exit 0 and `verdict.flaky === true`: go to **Flake diagnosis** (step 4).
   - Exit 1: read `working/verdict.json`, find the failing step (`typecheck`, `build` or `test-unit`), and continue to step 3.
   - Exit 2: it is a setup problem, not a regression. Read the message, fix the invocation (usually the project path) and run again.

3. **Fix loop** (at most 10 attempts in total).
   - Parse the failing step's `stderrTail` and `stdoutTail`. Identify the offending file(s) and line numbers.
   - Read those files.
   - Apply the smallest patch that addresses the error. Do not refactor speculatively: fix only what the error demands.
   - Run the script again. Use `--skip-tests` for quick iteration while typecheck or build is failing (tests only run when the build is green anyway).
   - When a run passes, do one final full run with no skip flags, so the report never claims tests passed when they were skipped. Then go to step 5.
   - If it still fails and the attempt count is below 10, loop.
   - On attempt 10, stop. Report the last error, show the partial diff, and do NOT commit anything.

4. **Flake diagnosis** (when `verdict.flaky === true`).
   - Read `verdict.flakyFailedTests`: the tests that failed on the first run and passed on the retry.
   - Spawn an investigation agent (`subagent_type: "general-purpose"`, no worktree needed). This agent type has no tool restriction, so the prompt itself must say it may not modify files. Give it:
     - the failing test names
     - the first-run stdout and stderr tails from the `test-unit` step in the verdict
     - the axes to check: (a) shared module-level state, (b) a cleanup gap (missing `afterEach` or `afterAll`), (c) order dependence, (d) a race (an async call that is not awaited), (e) an external dependency (database, network, timers)
     - an instruction to return a proposed diff and a rationale, with a suggested commit message `flake-fix: <test-name>`. It must not apply or commit anything.
   - When the agent returns, show its diagnosis and proposed patch to the user and state the root cause in one line.

5. **Report (success path).**
   - Run `git diff` in the project to capture every change the fix loop made.
   - Print a short report: typecheck, build and tests status, the number of attempts it took, and the diff (or a summary of changed files).
   - **Do NOT auto-commit.** Say what should be committed and let the user do it, so the fix diff is reviewed first.

## Manual invocation

```bash
# From a project directory
node ~/.claude/skills/guardian-check/lib/run-checks.mjs

# Explicit project path
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --project ~/code/my-app

# Quicker iteration while typecheck or build is failing
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --skip-tests

# Skip the build (known good, you only care about tests)
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --skip-build

# Write the verdict somewhere else (default: <skill dir>/working/verdict.json)
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --verdict /tmp/verdict.json

node ~/.claude/skills/guardian-check/lib/run-checks.mjs --help
```

## CI templates

The skill itself runs locally. The CI side is opt-in per repo: copy the template you want into `.github/workflows/`.

| Template | Purpose | Cost |
|---|---|---|
| `templates/ci-production-build.yml` | A blocking `production-build` job that runs `npm run build` on every PR. Catches the TS2589 class with no AI involved. | CI minutes only |
| `templates/ci-with-ai-guardian.yml` | Runs `claude --print` only when `production-build` fails: reads the error log, proposes patches, posts them as a PR comment. Needs an `ANTHROPIC_API_KEY` repo secret. Skips PRs from forks on purpose. | Capped at $0.50 per failing PR build; the actual cost depends on the log size and model |

To adopt:
1. Copy `templates/ci-production-build.yml` to `<repo>/.github/workflows/test.yml`. If you already have a workflow, copy only the `production-build` job into it.
2. Optional: copy `templates/ci-with-ai-guardian.yml` as well, and set the `ANTHROPIC_API_KEY` repo secret. Its `workflows:` list must match the `name:` of the workflow that holds `production-build` (the template assumes `Tests`).
3. Add `production-build` to the required status checks in your branch protection.

## Defect classes detected

The verdict records pass, fail, flaky or skipped per step, plus the output tails. It has no field for the class names below: they describe how to read a verdict, and the build classes are told apart by reading the error text.

| Class | Source | What it looks like |
|---|---|---|
| typecheck-fail | `npx tsc --noEmit` exits non-zero | TypeScript errors in the workspace, before the build |
| build-only-typecheck-fail | typecheck passes but `npm run build` fails | TS2589 instantiation too deep, `isolatedModules`-only errors, server/client boundary violations |
| build-non-ts-fail | `npm run build` fails without TS errors | Module not found, a missing env var, a server-component import constraint |
| test-fail (genuine) | the unit tests fail on the first run AND the retry | A real bug |
| test-flake | the first run fails, the retry passes | A race, shared state or a cleanup gap: diagnose, do not just retry |

## Prerequisites

- Node 18 or newer, and npm.
- A `package.json` in the project. A step is reported as `skipped` (never as failed) when the project lacks the thing it runs:
  - typecheck: a `tsconfig.json` (`npx tsc --noEmit`). TypeScript itself must be installed in the project: with a `tsconfig.json` but no local compiler the step fails, it is not skipped
  - build: a `build` script
  - tests: a `test:unit` script, or a `test` script (a bare `vitest` script is run as `npx vitest run` so it cannot hang in watch mode)
- The commands are npm-shaped. For pnpm or yarn, edit `TYPECHECK_CMD` and `BUILD_CMD` at the top of `lib/run-checks.mjs`.
- For the AI layer in CI: an `ANTHROPIC_API_KEY` repo secret and GitHub Actions enabled.

## Files

- `SKILL.md`: this file
- `lib/run-checks.mjs`: the detection CLI
- `working/verdict.json`: the last-run verdict (created on first run, not shipped)
- `templates/ci-production-build.yml`: copy-paste CI gate
- `templates/ci-with-ai-guardian.yml`: copy-paste AI-in-CI layer
