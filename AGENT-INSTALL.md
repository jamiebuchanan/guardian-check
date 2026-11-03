# Install guardian-check

You are installing guardian-check for the user: a Claude Code skill that runs the project's typecheck, production build and unit tests, fixes build failures in a loop, and sends an agent after the cause of a flaky test. Follow the sections below in order. Do not change any file in the repo you clone.

## Prerequisites

Check each one. If one is missing, stop and tell the user what to install.

- Claude Code: `claude --version`
- Node 18 or newer: `node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' && echo node ok`
- npm: `npm --version`
- git: `git --version`

## Locate config

The skill is a folder, `guardian-check`, copied into a Claude Code skills folder. There are two places it can go:

- Personal, for all the user's projects: `~/.claude/skills/guardian-check`
- Project, for one repo (the user can commit it to share with a team): `<repo>/.claude/skills/guardian-check`

Use the personal install unless the user asked for a project install. Before you install, check for an existing copy in both places:

```bash
ls -d ~/.claude/skills/guardian-check .claude/skills/guardian-check 2>/dev/null
```

`cp` overwrites a skill of the same name. If a copy already exists at the place you are about to install to, tell the user and ask before you continue.

## Install

Clone the repo into a temporary folder, then copy the skill into the skills folder you chose.

```bash
src="$(mktemp -d)"
git clone https://github.com/jamiebuchanan/guardian-check.git "$src/guardian-check"

# Personal install:
SKILLS_DIR="$HOME/.claude/skills"
# Project install instead (run from the repo root):
# SKILLS_DIR="$PWD/.claude/skills"

mkdir -p "$SKILLS_DIR"
cp -R "$src/guardian-check/skills/guardian-check" "$SKILLS_DIR/"
```

For a project install, `SKILL.md` says to use `.claude/skills/guardian-check/...` in its commands instead of `~/.claude/skills/guardian-check/...`. Check that the path in the `node` command in `$SKILLS_DIR/guardian-check/SKILL.md` matches where you installed it.

## Credentials

None. The skill needs no API key or environment variable.

## Validate

Set `SKILLS_DIR` again first if your shell does not keep variables between commands. This makes a tiny sample project in a temporary folder, runs the skill's check CLI on it and prints one line. It writes only to that temporary folder.

```bash
d="$(mktemp -d)" && printf '{"name":"sample","version":"1.0.0","scripts":{"build":"node -e 0","test":"node -e 0"}}' > "$d/package.json" && node "$SKILLS_DIR/guardian-check/lib/run-checks.mjs" --project "$d" --verdict "$d/verdict.json" >/dev/null && echo "ok: guardian-check ran build and tests on a sample project"
```

It should print `ok: guardian-check ran build and tests on a sample project`. Any other output means the install failed: report the error to the user.

The repo's own tests are a second check: `bash "$src/guardian-check/test/run.sh"` (every case should print `ok`, and the last line says `0 failed`).

## Verify live

This step needs the user's own project, so do not run it unless the user says to. It runs that project's typecheck, build and test scripts. Tell the user to start a new Claude Code session (a session open before the install may not see the skill), go to the project they want to check, and run:

```
/guardian-check
```

Or run the CLI directly with no Claude involved:

```bash
node "$SKILLS_DIR/guardian-check/lib/run-checks.mjs" --project <path to the user's project>
```

Exit code `0` means pass, `1` means a step failed, `2` means a setup problem such as no `package.json`. The target project needs a `package.json`, and a `tsconfig.json` with TypeScript installed if the user wants the typecheck step.

## Safety rules

- Do not overwrite an existing `guardian-check` skill without asking the user.
- Install to one place only: the personal folder or the project folder, not both.
- Do not edit files in the user's project during install or Validate.
- The skill runs the project's own build and test scripts, as the user would. Run Verify live only on projects the user trusts, and only when they ask.
- The skill's fix loop edits the working tree and never commits. Do not commit anything for the user.
- Never print or ask for secrets. This tool needs none.
