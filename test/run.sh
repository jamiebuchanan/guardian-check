#!/usr/bin/env bash
# test/run.sh: runs the detection CLI against tiny generated sample projects and
# checks the exit code and verdict for each scenario. Needs node and npm; ruby is
# used (when present) to check that the CI templates parse as YAML.
# Run from anywhere: bash test/run.sh
#
# Everything is written to a temporary directory. The sample projects use stub
# `tsc` and `vitest` binaries in node_modules/.bin, so no dependencies are
# installed and nothing touches the network.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
skill_src="$here/../skills/guardian-check"
pass=0; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Install the skill the way a user would, then test that copy. This also proves
# the layout works when dropped into a skills directory.
skills_dir="$tmp/home/.claude/skills"
mkdir -p "$skills_dir"
cp -R "$skill_src" "$skills_dir/guardian-check"
cli="$skills_dir/guardian-check/lib/run-checks.mjs"
verdict="$tmp/verdict.json"

check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "${3:-<nothing>}"; fi
}

# vget <dotted.path>: read a value out of the last verdict file.
vget() {
  node -e '
    const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    let x = v;
    for (const k of process.argv[2].split(".")) x = x == null ? undefined : x[k];
    console.log(x === undefined ? "<undefined>" : typeof x === "object" ? JSON.stringify(x) : String(x));
  ' "$verdict" "$1"
}

# guard <project-dir> [flags...]: run the CLI, print its exit code.
guard() {
  rm -f "$verdict"
  node "$cli" --project "$1" --verdict "$verdict" "${@:2}" >"$tmp/out.txt" 2>&1
  echo $?
}

# mkproj <name>: a sample project with a tsconfig, a build, a test script and a
# stub tsc. Behaviour is switched by marker files: FAIL_TYPECHECK, FAIL_BUILD,
# FAIL_TESTS (always fail) and FLAKE (fail once, then pass).
mkproj() {
  local d="$tmp/$1"
  mkdir -p "$d/node_modules/.bin"
  echo '{}' > "$d/tsconfig.json"
  cat > "$d/package.json" <<'JSON'
{ "name": "sample", "version": "1.0.0", "scripts": { "build": "node build.js", "test:unit": "node test.js" } }
JSON
  cat > "$d/node_modules/.bin/tsc" <<'JS'
#!/usr/bin/env node
if (require('fs').existsSync('FAIL_TYPECHECK')) {
  console.error('src/index.ts(3,7): error TS2322: Type string is not assignable to type number.');
  process.exit(1);
}
JS
  cat > "$d/build.js" <<'JS'
if (require('fs').existsSync('FAIL_BUILD')) {
  console.error('Type error: Type instantiation is excessively deep and possibly infinite. (TS2589)');
  process.exit(1);
}
console.log('built');
JS
  cat > "$d/test.js" <<'JS'
const fs = require('fs');
if (fs.existsSync('FAIL_TESTS')) {
  console.log('FAIL  sample > genuine failure');
  process.exit(1);
}
if (fs.existsSync('FLAKE') && !fs.existsSync('.flaked')) {
  fs.writeFileSync('.flaked', '1');
  console.log('FAIL  sample > flaky case');
  process.exit(1);
}
console.log('2 passed');
JS
  chmod +x "$d/node_modules/.bin/tsc"
  echo "$d"
}

echo "== CLI basics"
check "run-checks.mjs parses"                   0 "$(node --check "$cli" >/dev/null 2>&1; echo $?)"
check "--help exits 0"                          0 "$(node "$cli" --help >"$tmp/help.txt" 2>&1; echo $?)"
check "--help prints usage"                     yes "$(grep -q '^Usage:' "$tmp/help.txt" && echo yes)"
check "unknown flag exits 2"                    2 "$(node "$cli" --bogus >/dev/null 2>&1; echo $?)"
check "--project without a value exits 2"       2 "$(node "$cli" --project >/dev/null 2>&1; echo $?)"
mkdir -p "$tmp/empty"
check "no package.json exits 2"                 2 "$(guard "$tmp/empty")"
mkdir -p "$tmp/bare"; echo '{"name":"bare"}' > "$tmp/bare/package.json"
check "nothing to check exits 2"                2 "$(guard "$tmp/bare")"

echo "== All green"
p="$(mkproj green)"
check "green project exits 0"                   0 "$(guard "$p")"
check "verdict ok is true"                      true "$(vget ok)"
check "verdict flaky is false"                  false "$(vget flaky)"
check "typecheck passed"                        pass "$(vget summary.typecheck)"
check "build passed"                            pass "$(vget summary.build)"
check "tests passed"                            pass "$(vget summary.tests)"
check "three steps ran"                         3 "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).steps.length)' "$verdict")"

echo "== Failures"
p="$(mkproj tc-fail)"; touch "$p/FAIL_TYPECHECK"
check "typecheck failure exits 1"               1 "$(guard "$p")"
check "typecheck marked failed"                 fail "$(vget summary.typecheck)"
check "build skipped after typecheck failure"   skipped "$(vget summary.build)"
check "tests skipped after typecheck failure"   skipped "$(vget summary.tests)"
check "typecheck error is in the stderr tail"   yes "$(vget steps.0.stderrTail | grep -q TS2322 && echo yes)"

p="$(mkproj build-fail)"; touch "$p/FAIL_BUILD"
check "build failure exits 1"                   1 "$(guard "$p")"
check "typecheck passed before the build"       pass "$(vget summary.typecheck)"
check "build marked failed"                     fail "$(vget summary.build)"
check "tests skipped after build failure"       skipped "$(vget summary.tests)"
check "TS2589 is in the build stderr tail"      yes "$(vget steps.1.stderrTail | grep -q TS2589 && echo yes)"

p="$(mkproj test-fail)"; touch "$p/FAIL_TESTS"
check "genuine test failure exits 1"            1 "$(guard "$p")"
check "tests marked failed"                     fail "$(vget summary.tests)"
check "a genuine failure is not a flake"        false "$(vget flaky)"
check "failed tests were retried once"          test-unit-retry "$(vget steps.3.name)"

echo "== Flake detection"
p="$(mkproj flake)"; touch "$p/FLAKE"
check "flaky run exits 0"                       0 "$(guard "$p")"
check "verdict ok is true"                      true "$(vget ok)"
check "verdict flaky is true"                   true "$(vget flaky)"
check "tests marked flaky"                      flaky "$(vget summary.tests)"
check "flaky test is named"                     '["sample > flaky case"]' "$(vget flakyFailedTests)"

echo "== Skip flags"
p="$(mkproj skip-tests)"; touch "$p/FAIL_TESTS"
check "--skip-tests ignores failing tests"      0 "$(guard "$p" --skip-tests)"
check "tests reported as skipped"               skipped "$(vget summary.tests)"
p="$(mkproj skip-build)"; touch "$p/FAIL_BUILD"
check "--skip-build ignores a failing build"    0 "$(guard "$p" --skip-build)"
check "build reported as skipped"               skipped "$(vget summary.build)"
check "tests still run with --skip-build"       pass "$(vget summary.tests)"

echo "== Missing pieces are skipped, not failed"
p="$(mkproj no-tsconfig)"; rm "$p/tsconfig.json"
check "no tsconfig exits 0"                     0 "$(guard "$p")"
check "typecheck skipped without tsconfig"      skipped "$(vget summary.typecheck)"
check "build still runs"                        pass "$(vget summary.build)"
p="$(mkproj no-scripts)"
echo '{"name":"sample","scripts":{}}' > "$p/package.json"
check "tsconfig only exits 0"                   0 "$(guard "$p")"
check "build skipped without a build script"    skipped "$(vget summary.build)"
check "tests skipped without a test script"     skipped "$(vget summary.tests)"
p="$(mkproj all-skipped)"; rm "$p/tsconfig.json"
check "every step skipped exits 2"              2 "$(guard "$p" --skip-build --skip-tests)"
check "no verdict is written when nothing ran"  yes "$([ ! -f "$verdict" ] && echo yes)"

echo "== Test script fallback"
p="$(mkproj fallback-test)"
echo '{"name":"sample","scripts":{"build":"node build.js","test":"node test.js"}}' > "$p/package.json"
check "falls back to the test script"           0 "$(guard "$p")"
check "fallback runs npm test"                  "npm test" "$(vget steps.2.cmd)"
p="$(mkproj vitest-watch)"
echo '{"name":"sample","scripts":{"build":"node build.js","test":"vitest"}}' > "$p/package.json"
cat > "$p/node_modules/.bin/vitest" <<'JS'
#!/usr/bin/env node
// Stub: a bare `vitest` would watch forever; only `vitest run` is acceptable.
if (!process.argv.includes('run')) { console.error('watch mode would hang'); process.exit(1); }
console.log('1 passed');
JS
chmod +x "$p/node_modules/.bin/vitest"
check "bare vitest script runs as vitest run"   0 "$(guard "$p")"
check "vitest command is npx vitest run"        "npx vitest run" "$(vget steps.2.cmd)"

echo "== Installed layout"
p="$(mkproj default-verdict)"
(cd "$p" && node "$cli" >/dev/null 2>&1); code=$?
check "runs from the project directory"         0 "$code"
check "default verdict lands in the skill dir"  yes "$([ -f "$skills_dir/guardian-check/working/verdict.json" ] && echo yes)"
check "SKILL.md names the skill"                yes "$(grep -q '^name: guardian-check$' "$skills_dir/guardian-check/SKILL.md" && echo yes)"
check "SKILL.md has a description"              yes "$(grep -q '^description: ' "$skills_dir/guardian-check/SKILL.md" && echo yes)"

echo "== CI templates"
if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
  yaml_job() { ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts(y["jobs"] && y["jobs"].key?(ARGV[1]) ? "yes" : "no")' "$1" "$2" 2>/dev/null; }
  check "production-build template parses"      yes "$(yaml_job "$skill_src/templates/ci-production-build.yml" production-build)"
  check "AI guardian template parses"           yes "$(yaml_job "$skill_src/templates/ci-with-ai-guardian.yml" guardian-diagnose)"
else
  echo "skip  CI template YAML checks (ruby with yaml not available)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
