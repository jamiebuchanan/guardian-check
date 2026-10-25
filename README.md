# guardian-check

A Claude Code skill that stops "green locally, red on deploy". It runs your typecheck, your production build and your unit tests, fixes build failures in a loop, and when a test fails once and then passes, sends an agent after the cause instead of quietly retrying.

## Why

The failure it exists for: `tsc --noEmit` passes, you push, and the host (Vercel, Railway, your CI) fails the production build. TS2589 "type instantiation is excessively deep", `isolatedModules`-only errors and server/client boundary violations all pass a plain typecheck and fail `next build`. The cheap fix is to run the real build before you push. This skill automates that, and lets Claude read a failure and patch it.

The second failure it targets is the flaky test that gets retried until it goes away. Retrying hides a race or a cleanup gap that will come back. This skill records which tests failed on the first run and hands them to an agent that looks for the root cause. The agent is told to change nothing and only propose a patch.

## What's in the box

| Path | What it is |
|---|---|
| `skills/guardian-check/SKILL.md` | The skill. Tells Claude how to run the check, loop on fixes (at most 10 attempts, never commits) and diagnose flakes. |
| `skills/guardian-check/lib/run-checks.mjs` | The detection CLI. Plain Node, no dependencies. Runs typecheck, build and tests, retries a failed test run once, writes a JSON verdict. Never edits your source. |
| `skills/guardian-check/templates/ci-production-build.yml` | A GitHub Actions workflow with a blocking `production-build` job. No AI, just the real build on every PR. |
| `skills/guardian-check/templates/ci-with-ai-guardian.yml` | Optional GitHub Actions workflow that runs `claude --print` when that build fails and posts proposed patches as a PR comment. |
| `test/run.sh` | Runs the CLI against generated sample projects and checks every outcome. |

There are two layers on purpose. The CLI is deterministic and stateless, so its verdict can be trusted and reused (by you, by CI, by another tool). The skill is the part that needs an edit tool and the ability to spawn an agent, which a CLI cannot do.

### What it detects

The verdict records pass, fail, flaky or skipped per step, plus the output tails. It has no field for the class names below: they describe how to read a verdict, and the two build classes are told apart by reading the error text.

| Class | What it looks like |
|---|---|
| typecheck-fail | `npx tsc --noEmit` exits non-zero. |
| build-only-typecheck-fail | Typecheck passes, `npm run build` fails: TS2589, `isolatedModules` errors, server/client boundary violations. |
| build-non-ts-fail | The build fails without TS errors: module not found, a missing env var, a server-component import constraint. |
| test-fail (genuine) | The unit tests fail on the first run and on the retry. A real bug. |
| test-flake | The first run fails, the retry passes. Diagnosed rather than ignored. |

A step the project has no way to run (no `tsconfig.json`, no `build` script, no test script) is reported as `skipped`, never as `failed`, so a missing script cannot be mistaken for a regression.

## Install

Requirements: Claude Code, Node 18 or newer, npm. The target project needs a `package.json`, and a `tsconfig.json` with TypeScript installed if you want the typecheck step.

```bash
git clone https://github.com/jamiebuchanan/guardian-check.git
cd guardian-check
bash test/run.sh                                   # every case should pass first

mkdir -p ~/.claude/skills
cp -R skills/guardian-check ~/.claude/skills/      # personal, all projects
# or, for one repo (commit it to share with your team):
# mkdir -p <repo>/.claude/skills && cp -R skills/guardian-check <repo>/.claude/skills/
```

The `cp` overwrites a skill of the same name, so check `~/.claude/skills` first if you already have one. For a project-level install, change the path in the commands inside `SKILL.md` to `.claude/skills/guardian-check/...`.

## Use

In Claude Code, from the project you want to check:

```
/guardian-check
/guardian-check ~/code/my-app
```

or just ask: "pre-flight the build", "verify before push", "check for regressions". Claude runs the CLI, reads the verdict, and works the loop. It stops after 10 failed attempts and it never commits. Review `git diff` when it finishes.

If the skill is not found after installing, start a new Claude Code session. Claude Code's own permission settings still apply, so expect prompts to approve the `node` command and the file edits unless you have allowed them.

You can also run the CLI directly, with no Claude involved:

```bash
node ~/.claude/skills/guardian-check/lib/run-checks.mjs                       # current directory
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --project ~/code/my-app
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --skip-tests          # typecheck and build only
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --skip-build          # typecheck and tests only
node ~/.claude/skills/guardian-check/lib/run-checks.mjs --verdict ./verdict.json
```

Exit codes: `0` pass (a flake that passes on retry is a pass, with `flaky: true`), `1` a step failed, `2` setup problem (no `package.json`, nothing to check or every step skipped, bad flag).

## Example run

Both runs below are against a tiny sample project with stub tools, the same kind `test/run.sh` generates. A real project prints the same lines.

A test that fails once and passes on retry:

```
→ typecheck (npx tsc --noEmit)
  ✓ passed
→ production build (npm run build)
  ✓ passed
→ unit tests (npm run test:unit)
  ✗ failed first try (exit 1), retrying once for flake detection
  ⚠ retry passed: FLAKE detected. 1 failing test(s) on first run.

Verdict: /tmp/guardian-demo/verdict.json
  typecheck: pass
  build:     pass
  tests:     flaky (1 flaky)
```

Exit code 0, with `flaky: true` and `flakyFailedTests: ["checkout > applies the discount once"]` in the verdict. That is the signal for the skill to spawn the diagnostic agent.

A build that typecheck did not catch:

```
→ typecheck (npx tsc --noEmit)
  ✓ passed
→ production build (npm run build)
  ✗ failed (exit 1)
⏭  skip tests (an earlier step failed)

Verdict: /tmp/guardian-demo/verdict.json
  typecheck: pass
  build:     fail
  tests:     skipped
```

Exit code 1. The skill reads `stderrTail` from the `build` step, patches the file the error names, and runs the CLI again.

### The verdict file

By default it is written to `working/verdict.json` inside the installed skill folder, and overwritten on each run. Pass `--verdict <path>` to put it elsewhere, which you will want if you run checks on several projects at once.

```json
{
  "ok": true,
  "flaky": false,
  "flakyFailedTests": [],
  "project": "/path/to/project",
  "timestamp": "2026-10-23T10:28:34.338Z",
  "steps": [
    { "name": "typecheck", "cmd": "npx tsc --noEmit", "ok": true, "exitCode": 0, "durationMs": 193, "stdoutTail": "", "stderrTail": "" }
  ],
  "summary": { "typecheck": "pass", "build": "pass", "tests": "pass" }
}
```

Each step keeps the last 30 lines of stdout and stderr. `summary.tests` is one of `pass`, `fail`, `flaky` or `skipped`.

## CI templates

The skill runs on your machine. To get the same gate on every pull request, copy a template into `.github/workflows/`:

1. `ci-production-build.yml` adds a blocking `production-build` job. Add it to your branch protection's required checks. It costs CI minutes only. It assumes npm and a committed `package-lock.json` (it runs `npm ci`).
2. `ci-with-ai-guardian.yml` (optional) runs only when that build fails on a pull request, asks Claude for a diagnosis and patches, and posts them as a PR comment. It needs an `ANTHROPIC_API_KEY` repo secret and is capped at $0.50 per run (`--max-budget-usd`). What a run costs depends on the size of the error log and the model; the cap is the most it can spend. It never pushes a commit. Its `workflows:` list must match the `name:` of the workflow that holds `production-build`.

The AI template skips pull requests from forks. A `workflow_run` job can read your repo secrets and this one runs the PR's code (`npm ci`, then the build), which for a fork would be untrusted code next to your secrets.

## Limits

- **npm-shaped.** The commands are `npx tsc --noEmit` and `npm run build`, plus `npm run test:unit` or `npm test`. For pnpm or yarn, edit `TYPECHECK_CMD` and `BUILD_CMD` at the top of `run-checks.mjs`. A bare `vitest` test script is run as `npx vitest run` so it cannot hang in watch mode.
- **One retry.** A test that fails on the first run and passes on the second is called a flake. A test that fails one run in ten can pass both and go unnoticed, and a genuine bug that happens to be intermittent is called a flake too. The agent's diagnosis is the check on that.
- **Test names are best-effort.** Failing test names are pulled from `FAIL`, `×` and `❯` lines, which suits Vitest and Jest style output. Other runners still get the flake detected and the output tails recorded, with an empty name list.
- **Root `tsconfig.json` only.** In a monorepo it checks the project root you pass, not each workspace.
- **TypeScript must be installed.** A project with a `tsconfig.json` but no local TypeScript fails the typecheck step (`npx tsc` finds no compiler). It is not skipped.
- **No environment set up.** The build runs with your current environment. A build that needs env vars you have not set fails as `build-non-ts-fail`.
- **It runs your project's code.** Build and test scripts execute as they would for you. Point it at projects you trust.
- **The fix loop edits your working tree.** It makes the smallest patch the error names, up to 10 attempts, and never commits. Start from a clean branch so `git diff` shows only its changes.

Tested on macOS with Node 24 and Node 26. Linux and Windows are untested.

## Tests

```bash
bash test/run.sh
```

It copies the skill into a throwaway `~/.claude/skills` layout, generates sample projects (with stub `tsc` and `vitest` binaries, so nothing is installed and nothing touches the network), and checks the exit code and verdict for: all green, typecheck failure, build failure, genuine test failure, flake detection, both skip flags, missing scripts and tsconfig, a run where every step is skipped, the test-script fallback, the default verdict location, and that both CI templates parse as YAML (when `ruby` is available). It writes only to a temporary directory.

## Credits

Written by Jamie Buchanan. There is no upstream project: this is original work, and the only borrowed piece is the skill file format, which is Claude Code's. See the [skills documentation](https://code.claude.com/docs/en/skills).

## Licence

MIT. See [LICENSE](LICENSE).
