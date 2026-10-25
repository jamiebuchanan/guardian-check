#!/usr/bin/env node
/**
 * Deterministic build and test gate for the guardian-check skill.
 *
 * Runs the production-equivalent pipeline (typecheck, build, unit tests) and
 * writes a machine-readable verdict to working/verdict.json. Detects flakes by
 * re-running a failed unit-test step once; if the retry passes, the run is
 * marked "flaky" and the failing test names are recorded so the orchestrating
 * skill can dispatch a diagnostic agent.
 *
 * Usage:
 *   node run-checks.mjs                          # full pipeline (typecheck, build, tests)
 *   node run-checks.mjs --skip-tests             # typecheck and build only
 *   node run-checks.mjs --skip-build             # typecheck and tests only
 *   node run-checks.mjs --project <path>         # project to check (default: current directory)
 *   node run-checks.mjs --verdict <path>         # where to write the verdict
 *                                                # (default: <skill dir>/working/verdict.json)
 *
 * Exit codes: 0 = pass (a flake that passes on retry counts as a pass),
 *             1 = a step failed, 2 = usage or setup problem (nothing was checked).
 *
 * The script does NOT modify source files. It captures errors. The fix loop
 * lives in the orchestrating skill: Claude reads the verdict, patches with its
 * edit tool, then runs this script again.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Edit these two lines if your project uses another package manager.
const TYPECHECK_CMD = 'npx tsc --noEmit';
const BUILD_CMD = 'npm run build';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL_DIR = resolve(__dirname, '..');
const DEFAULT_VERDICT = resolve(SKILL_DIR, 'working', 'verdict.json');

const USAGE = 'Usage: run-checks.mjs [--skip-tests] [--skip-build] [--project <path>] [--verdict <path>]';
const FLAGS = new Set(['--skip-tests', '--skip-build', '--help', '-h']);
const VALUE_FLAGS = new Set(['--project', '--verdict']);

function parseArgs(argv) {
  const out = { flags: new Set(), values: {}, error: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (FLAGS.has(a)) {
      out.flags.add(a);
    } else if (VALUE_FLAGS.has(a)) {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) {
        out.error = `${a} needs a value`;
        break;
      }
      out.values[a] = v;
    } else {
      out.error = `unknown argument: ${a}`;
      break;
    }
  }
  return out;
}

function runStep(name, cmd, cwd) {
  const startedAt = Date.now();
  // A large build log would overflow spawnSync's default 1 MB buffer and look
  // like a failure, so the buffer is raised well above any realistic log.
  const result = spawnSync(cmd, {
    cwd,
    shell: true,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  const durationMs = Date.now() - startedAt;
  const ok = result.status === 0;
  return {
    name,
    cmd,
    ok,
    exitCode: result.status,
    durationMs,
    stdout: (result.stdout ?? '').slice(-8000),
    stderr: (result.stderr ?? '').slice(-8000),
  };
}

function extractFailingTests(testOutput) {
  // Heuristic for Vitest/Jest style output: lines containing a failure marker
  // followed by a test name. Good enough to name the flaky tests for the
  // diagnostic agent; the stdout/stderr tails in the verdict carry the detail.
  const fails = [];
  for (const line of testOutput.split('\n')) {
    const m = line.match(/(?:❯|FAIL|×)\s+([^\s].*?)(?:\s+\d+ms)?$/);
    if (m) fails.push(m[1].trim());
  }
  return [...new Set(fails)].slice(0, 20);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.error) {
    console.error(`✗ ${args.error}\n${USAGE}`);
    process.exit(2);
  }
  if (args.flags.has('--help') || args.flags.has('-h')) {
    console.log(USAGE);
    process.exit(0);
  }

  const project = args.values['--project']
    ? resolve(args.values['--project'])
    : process.cwd();

  if (!existsSync(join(project, 'package.json'))) {
    console.error(`✗ No package.json at ${project}. Pass --project <path> or cd into the project first.`);
    process.exit(2);
  }

  const verdictPath = args.values['--verdict']
    ? resolve(args.values['--verdict'])
    : DEFAULT_VERDICT;

  const steps = [];
  const allGreen = () => steps.every((s) => s.ok);

  // Resolve what can actually run. A missing script must read as "skipped",
  // never as "failed", or it is indistinguishable from a genuine regression.
  const pkg = JSON.parse(readFileSync(join(project, 'package.json'), 'utf8'));
  const scripts = pkg.scripts ?? {};
  const hasTsconfig = existsSync(join(project, 'tsconfig.json'));
  const buildCmd = scripts.build ? BUILD_CMD : null;
  // Prefer test:unit, fall back to a non-watch `test`.
  const testCmd = scripts['test:unit']
    ? 'npm run test:unit'
    : scripts.test
      // `vitest` with no arguments watches forever; force a single run.
      ? (/^vitest\b/.test(scripts.test) ? 'npx vitest run' : 'npm test')
      : null;

  if (!hasTsconfig && !buildCmd && !testCmd) {
    console.error('✗ Nothing to check: no tsconfig.json, no "build" script and no "test:unit" or "test" script.');
    process.exit(2);
  }

  // Step 1: TypeScript
  if (hasTsconfig) {
    console.log(`→ typecheck (${TYPECHECK_CMD})`);
    steps.push(runStep('typecheck', TYPECHECK_CMD, project));
    console.log(steps.at(-1).ok ? '  ✓ passed' : `  ✗ failed (exit ${steps.at(-1).exitCode})`);
  } else {
    console.log('⏭  skip typecheck (no tsconfig.json)');
  }

  // Step 2: production build (the step that catches what typecheck misses)
  if (args.flags.has('--skip-build')) {
    console.log('⏭  skip build (--skip-build)');
  } else if (!buildCmd) {
    console.log('⏭  skip build (no "build" script in package.json)');
  } else if (!allGreen()) {
    console.log('⏭  skip build (typecheck failed)');
  } else {
    console.log(`→ production build (${buildCmd})`);
    steps.push(runStep('build', buildCmd, project));
    console.log(steps.at(-1).ok ? '  ✓ passed' : `  ✗ failed (exit ${steps.at(-1).exitCode})`);
  }

  // Step 3: unit tests, with flake detection
  let flaky = false;
  let flakyFailedTests = [];
  if (args.flags.has('--skip-tests')) {
    console.log('⏭  skip tests (--skip-tests)');
  } else if (!testCmd) {
    console.log('⏭  skip tests (no "test:unit" or "test" script in package.json)');
  } else if (!allGreen()) {
    console.log('⏭  skip tests (an earlier step failed)');
  } else {
    console.log(`→ unit tests (${testCmd})`);
    const first = runStep('test-unit', testCmd, project);
    steps.push(first);
    if (first.ok) {
      console.log('  ✓ passed first try');
    } else {
      console.log(`  ✗ failed first try (exit ${first.exitCode}), retrying once for flake detection`);
      flakyFailedTests = extractFailingTests(first.stdout + '\n' + first.stderr);
      const second = runStep('test-unit-retry', testCmd, project);
      steps.push(second);
      if (second.ok) {
        flaky = true;
        console.log(`  ⚠ retry passed: FLAKE detected. ${flakyFailedTests.length} failing test(s) on first run.`);
      } else {
        console.log(`  ✗ retry also failed (exit ${second.exitCode}), genuine failure, not a flake`);
      }
    }
  }

  // Every step was skipped (for example both --skip flags and no tsconfig.json).
  // Nothing was checked, which is a usage problem and not a failed step, so it
  // must not exit 1: the orchestrating skill would go looking for a failure.
  if (steps.length === 0) {
    console.error('✗ Nothing was run: every step was skipped. Drop a --skip flag, or add a tsconfig.json, a "build" script or a test script.');
    process.exit(2);
  }

  // Verdict
  const lastByName = (name) => [...steps].reverse().find((s) => s.name === name);
  const typecheck = lastByName('typecheck');
  const build = lastByName('build');
  const testInitial = steps.find((s) => s.name === 'test-unit');
  const testRetry = lastByName('test-unit-retry');

  // A flake leaves one failed step (the first test run) in the list, so "every
  // step passed" is too strict: the retry passing is what counts.
  const ok = steps.length > 0 && (allGreen() || (flaky && (typecheck?.ok ?? true) && (build?.ok ?? true) && testRetry?.ok));

  const verdict = {
    ok,
    flaky,
    flakyFailedTests,
    project,
    timestamp: new Date().toISOString(),
    steps: steps.map((s) => ({
      name: s.name,
      cmd: s.cmd,
      ok: s.ok,
      exitCode: s.exitCode,
      durationMs: s.durationMs,
      stdoutTail: s.stdout.split('\n').slice(-30).join('\n'),
      stderrTail: s.stderr.split('\n').slice(-30).join('\n'),
    })),
    summary: {
      typecheck: typecheck ? (typecheck.ok ? 'pass' : 'fail') : 'skipped',
      build: build ? (build.ok ? 'pass' : 'fail') : 'skipped',
      tests: testInitial
        ? (testInitial.ok ? 'pass' : (testRetry?.ok ? 'flaky' : 'fail'))
        : 'skipped',
    },
  };

  mkdirSync(dirname(verdictPath), { recursive: true });
  writeFileSync(verdictPath, JSON.stringify(verdict, null, 2));
  console.log(`\nVerdict: ${verdictPath}`);
  console.log(`  typecheck: ${verdict.summary.typecheck}`);
  console.log(`  build:     ${verdict.summary.build}`);
  console.log(`  tests:     ${verdict.summary.tests}${flaky ? ` (${flakyFailedTests.length} flaky)` : ''}`);

  process.exit(ok ? 0 : 1);
}

try {
  main();
} catch (err) {
  console.error(err);
  process.exit(2);
}
