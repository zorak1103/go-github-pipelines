---
name: building-go-github-pipelines
description: Use when setting up, updating, or auditing GitHub Actions CI/CD pipelines for Go projects on GitHub. Triggers include: project has no CI, workflows use Dependabot instead of Renovate, total-coverage instead of per-file gate, legacy dockers config, Codecov dependency, unpinned tool versions, missing secret scanning, or missing govulncheck ignore-list gate.
---

# Building Go GitHub Pipelines

## Overview

Assembles a complete, self-consistent GitHub Actions pipeline for Go projects from
versioned templates. Encodes the best patterns distilled from five production repos
(ha-mcp, dlia, notebook, bka-go, car-check). Generates both CI workflow and companion
files (golangci.yml, Taskfile, coverage script, GoReleaser config, Renovate config,
Dockerfile) so a bare repo can be fully bootstrapped.

## Step 1 — Detect

Read these files/paths and record what exists:

| Check | If present → |
|---|---|
| `go.mod` | Extract `module` path → `{{MODULE}}`, last segment → `{{PROJECT}}` |
| `frontend/` or root `package.json` | Enable **Frontend+Embed block** |
| Existing `.goreleaser.yaml` | Note release style (upgrade legacy `dockers` → `dockers_v2`) |
| Existing `Dockerfile` | Enable **Docker block** |
| `go.mod` extra external test tool (e.g. typst, ffmpeg) | Enable **Extra-Toolchain block** |
| No `.github/workflows/` at all | Full bootstrap mode |

Ask the user for:
- `{{GITHUB_USER}}` — GitHub username (e.g. `zorak1103`). Used for Renovate gitAuthor and wrapcheck module glob.
- `{{DOCKER_USER}}` — Docker Hub username (same as `{{GITHUB_USER}}` in most cases; confirm if they differ)
- Release style: **GoReleaser** (default) or **manual matrix** (no Docker, just binaries)?
- Does this project publish to Docker Hub? (sets whether release+Docker block is included)
- **Mutation testing?** Add a blocking, diff-scoped `mutest` gate on pull requests plus a local pre-push check? (default **No**). This is an opt-in v0.x tool; disclose the supply-chain trade-off before enabling it.

Also detect:
- **Project type** — Check `./cmd/*/` and `./main.go`: if there is a `cmd/` binary entry point with no HTTP server / gRPC handler patterns, treat as **CLI**. Otherwise treat as **service/library**. For CLI projects, remove the `profile:service-only` linters from `.golangci.yml` (wrapcheck, noctx).
- **Existing golangci config** — If `.golangci.yml` already exists and is non-trivial (has `linters.enable` with 5+ linters), preserve its rigor (use strict thresholds from the template). If absent or minimal (e.g., only `go vet`), ask the user: "Start with strict thresholds (funlen:60/40, gocognit:23, gocyclo:15) or onboarding thresholds (funlen:80/50, gocognit:30, gocyclo:20)?" Use the onboarding values to avoid 365-findings-on-first-run.

Derive: `{{DOCKER_IMAGE}}` = `{{DOCKER_USER}}/{{PROJECT}}`

### Pre-flight checks (run before generating any files)

Before writing any output, verify the project is in a state that CI can run successfully:

| Check | Command | Action if fails |
|---|---|---|
| Binary entry point is committed | `git ls-files cmd/` | Warn: "cmd/ is not tracked by git — check .gitignore for patterns that match source directories" |
| Test fixtures are committed | `git ls-files testdata/` | Warn: "testdata/ is not tracked — fixtures may be gitignored; tests may pass locally but fail on CI" |
| .gitignore doesn't shadow sources | `grep -E '^(cmd|internal|pkg|testdata)' .gitignore` | Warn if any match: "Pattern may gitignore source code — check immediately" |

## Step 2 — Go Toolchain Alignment

The pipeline derives its Go version from `go.mod` alone (`go-version-file: go.mod` on every
`setup-go`). When the user requests a Go update, bring `go.mod` to the newest stable release,
but **never silently**: discover, propose, show the diff, confirm, then verify.

### 2a — Discover the current stable release

```bash
GO_JSON=$(curl -fsSL 'https://go.dev/dl/?mode=json')
if command -v jq >/dev/null 2>&1; then
  GO_LATEST=$(printf '%s' "$GO_JSON" | jq -r 'map(select(.stable))[0].version')
else
  GO_LATEST=$(printf '%s' "$GO_JSON" \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"go[0-9]+(\.[0-9]+)*"' \
    | head -1 | grep -oE 'go[0-9]+(\.[0-9]+)*')
fi
GO_LANG=$(printf '%s' "${GO_LATEST#go}" | cut -d. -f1,2)
if [[ ! "$GO_LATEST" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ || -z "$GO_LANG" ]]; then
  echo "Could not determine a stable Go release; stop instead of guessing."
  exit 1
fi
```

The feed is newest-first. Do not assume `jq` is installed; the fallback tolerates the real
`"version": "go1.27.1"` spacing. If discovery fails or `GO_LATEST` is empty, stop instead of
guessing a version.

### 2b — Read the current state and refuse to downgrade

```bash
if command -v jq >/dev/null 2>&1; then
  OLD_GO=$(go mod edit -json | jq -r '.Go // "none"')
  OLD_TOOLCHAIN=$(go mod edit -json | jq -r '.Toolchain // "none"')
else
  OLD_GO=$(sed -n 's/^go[[:space:]]\+//p' go.mod | head -1)
  OLD_TOOLCHAIN=$(sed -n 's/^toolchain[[:space:]]\+//p' go.mod | head -1)
  OLD_GO=${OLD_GO:-none}
  OLD_TOOLCHAIN=${OLD_TOOLCHAIN:-none}
fi
```

Without `jq`, read `^go ` and `^toolchain ` from `go.mod`. Compare both the language and toolchain
versions before editing:

```bash
if [ "$OLD_GO" != "none" ] && [ "$(printf '%s\n' "$OLD_GO" "$GO_LANG" | sort -V | tail -1)" != "$GO_LANG" ]; then
  echo "go.mod is newer than the discovered stable release; refusing to downgrade."
  exit 1
fi
if [ "$OLD_TOOLCHAIN" != "none" ] && [ "$(printf '%s\n' "${OLD_TOOLCHAIN#go}" "${GO_LATEST#go}" | sort -V | tail -1)" != "${GO_LATEST#go}" ]; then
  echo "go.mod toolchain is newer than the discovered stable release; refusing to downgrade."
  exit 1
fi
```

If the current language or toolchain version is newer than the discovered stable release, stop and
report; never downgrade a release candidate. If both directives already match, report "already
current" and continue. Run `go env GOTOOLCHAIN`; warn if it is
`local`, because local builds will require the new installed toolchain after the edit.

### 2c — Propose the edit, show the diff, and wait

Use the two-line form:

```text
go 1.27
toolchain go1.27.1
```

`actions/setup-go` supports both directives and uses `toolchain` when present, so CI remains
reproducible at the exact patch release while the `go` directive expresses the language floor.
Do not write `go 1.27.1` as the language directive.

```bash
cp go.mod /tmp/go.mod.before
if [ -f go.sum ]; then
  cp go.sum /tmp/go.sum.before
else
  rm -f /tmp/go.sum.before
fi
if [ "$GO_LATEST" = "go${GO_LANG}" ]; then
  go mod edit -go="$GO_LANG" -toolchain=none
else
  go mod edit -go="$GO_LANG" -toolchain="$GO_LATEST"
fi
diff -u /tmp/go.mod.before go.mod
```

`go mod edit` is textual and offline, so no dependency versions move under the user's review.
Show the diff and **stop**. Make no further changes until the user explicitly confirms. If they
decline, restore the snapshot with:

```bash
cp /tmp/go.mod.before go.mod
if [ -f /tmp/go.sum.before ]; then
  cp /tmp/go.sum.before go.sum
else
  rm -f go.sum
fi
```

### 2d — Verify after confirmation

Run, in order:

```bash
go mod tidy
go build ./...
go test ./...
```

Report each result. If any command fails, do not proceed to Step 3 with a red build. Offer either
rollback — restore the snapshot (using `-toolchain=none` when there was no prior toolchain) and
re-run the build — or fix forward and repeat verification.

### 2e — What does not change

- Do **not** add `run.go` to `.golangci.yml`; v2 resolves the Go version from `go.mod` and a
  `run.go` value would create a second source of truth. Remove an existing generated `run.go` if
  it contradicts this rule.
- Do **not** add a workflow `GO_VERSION` variable or a new Go-version customManager. Every
  `setup-go` already reads `go.mod`; Renovate's built-in `gomod` manager handles the directives.
- Do not change `Dockerfile.tmpl` or `goreleaser.yaml.tmpl`; neither hardcodes a Go version.

## Step 3 — Block Inventory

### Always-On (every Go project)
- `ci.yml` — lint, test/coverage, build, govulncheck, secret-detection
- `renovate.yml` + `renovate.json` — daily dep updates via Renovate
- `.golangci.yml` — full ~30-linter config (v2 schema)
- `scripts/check-coverage.sh` — configurable coverage gate (per-file default, 80% threshold), honors `// coverage-exempt:`; modes: per-file (default), per-function (strictest), total
- `.govulncheck-ignore` — ignore-list for CVEs without fixes
- `.githooks/pre-commit` + `.githooks/pre-push` — local format/lint hooks, generated but inert until `task install-hooks` sets `core.hooksPath`; bypass with `--no-verify`

### Conditional
| Block | Template file | Activate when |
|---|---|---|
| Frontend+Embed | `blocks/frontend-embed.yml` | `frontend/` or root `package.json` |
| Release (GoReleaser) | `templates/workflows/release-goreleaser.yml.tmpl` | Docker/packages release |
| Release (matrix) | `templates/workflows/release-matrix.yml.tmpl` | Binary-only, no Docker |
| Docker runtime | `templates/Dockerfile.tmpl` | GoReleaser release |
| GoReleaser config | `templates/goreleaser.yaml.tmpl` | GoReleaser release |
| Extra toolchain | `blocks/extra-toolchain.yml` | External binary needed for tests |
| Taskfile | `templates/Taskfile.yml.tmpl` | No existing Taskfile.yml |
| Mutation testing | `blocks/mutest.yml` | User opted in; adds a PR-only diff-scoped job, mutest Taskfile tasks, and the pre-push mutation region |

**Golden rule:** Never emit a `task <name>` step without the corresponding task in `Taskfile.yml`.
Never emit `task build:frontend` without the Frontend+Embed block active.

**Integration tests:** If the project has a `//go:build integration` tag pattern or a
`test:integration` task, split the `test` job into `unit-test` + `integration-test` +
`coverage` jobs (bka-go pattern). The Extra-Toolchain block is often needed alongside this.

**Binary name:** Check `./cmd/*/` directories — the folder name is the binary name
(e.g. `./cmd/server/` → BINARY=`server`). Use PROJECT only as a fallback.

## Step 4 — Placeholders

| Placeholder | Source | Example |
|---|---|---|
| `{{MODULE}}` | `go.mod` first line | `github.com/zorak1103/ha-mcp` |
| `{{PROJECT}}` | Last path segment of MODULE | `ha-mcp` |
| `{{BINARY}}` | Check `./cmd/*/` dirs first; fall back to PROJECT | `ha-mcp` or `server` |
| `{{DOCKER_USER}}` | User-provided | `zorak1103` |
| `{{GITHUB_USER}}` | User-provided (same as DOCKER_USER unless they differ) | `zorak1103` |
| `{{DOCKER_IMAGE}}` | `{{DOCKER_USER}}/{{PROJECT}}` | `zorak1103/ha-mcp` |
| `{{GOLANGCI_VERSION}}` | Latest golangci-lint v2 | `v2.12.2` |
| `{{GOVULNCHECK_VERSION}}` | Latest govulncheck | `v1.3.0` |
| `{{GORELEASER_VERSION}}` | Latest goreleaser | `v2.16.0` |
| `{{TOOL_NAME}}` | External test tool name (Extra-Toolchain block) | `typst` |
| `{{TOOL_NAME_UPPER}}` | Uppercase of TOOL_NAME (for env var names) | `TYPST` |
| `{{TOOL_VERSION}}` | External tool version (Extra-Toolchain block) | `0.14.2` |
| `{{NODE_VERSION}}` | Node.js version (Frontend+Embed block) | `24` |
| `{{MUTEST_VERSION}}` | Latest mutest release tag; pin it, never `@latest` | `v0.6.1` |
| `{{SKILL_VERSION}}` | Version from `.claude-plugin/plugin.json` | `1.2.0` |

### Placeholder disambiguation

Three similar syntaxes appear in the templates — only `{{UPPERCASE}}` markers are yours to substitute:

| Syntax | Owner | Action |
|---|---|---|
| `{{UPPERCASE_SNAKE}}` | This skill | **Substitute** with actual value |
| `{{.CamelCase}}` | GoReleaser (`text/template`) | **Leave as-is** in `.goreleaser.yaml` |
| `${{ expression }}` | GitHub Actions | **Leave as-is** in workflow YAML |

Never substitute placeholders inside `${{ }}` expressions or GoReleaser `{{.Variable}}` references.

**Profile selection:** After placeholder substitution, apply the project profile:
- **CLI projects**: remove linters marked `# profile:service-only` from `linters.enable` in `.golangci.yml` (wrapcheck, noctx)
- **Onboarding strictness**: if user chose onboarding thresholds, update the funlen/gocognit/gocyclo settings in `.golangci.yml` to the onboarding values noted in the template comments

## Step 5 — Generate Files

Write these files (always-on first, then conditionals):

```
.github/
  workflows/
    ci.yml                        ← from templates/workflows/ci.yml.tmpl
    renovate.yml                  ← from templates/workflows/renovate.yml.tmpl
    release.yml                   ← from release-goreleaser or release-matrix tmpl
.githooks/
  pre-commit                      ← from templates/githooks/pre-commit (chmod +x)
  pre-push                        ← from templates/githooks/pre-push (chmod +x)
.golangci.yml                     ← from templates/golangci.yml.tmpl
scripts/
  check-coverage.sh               ← from templates/check-coverage.sh (chmod +x)
.govulncheck-ignore               ← from templates/govulncheck-ignore.tmpl
renovate.json                     ← from templates/renovate.json.tmpl
Taskfile.yml                      ← from templates/Taskfile.yml.tmpl (if missing; upgrade with required hook/mutest tasks when present)
.goreleaser.yaml                  ← from templates/goreleaser.yaml.tmpl (if GoReleaser)
Dockerfile                        ← from templates/Dockerfile.tmpl (if Docker)
```

Do NOT overwrite files that already exist and are correct — compare and upgrade instead.

**Upgrading older generated configs:** v1.2.0 is not a minor bump — it changes how Go's toolchain version is managed (from a pinned `GO_VERSION` env var to `go-version-file: go.mod`). If you generated CI config with v1.1.0 or earlier, regenerate with `/go-github-pipelines` to adopt the new pattern. Manually patching is error-prone.

Legacy pattern upgrades to always apply:
- `dockers:` + `docker_manifests:` → `dockers_v2:` in goreleaser config
- `golangci-lint-action` step → `go install` pinned step
- `govulncheck@latest` plain run → ignore-list gate
- `@main` action pins → versioned pins
- `GO_VERSION` env var + `go-version: ${{ env.GO_VERSION }}` on `setup-go` steps → drop the env var and switch to `go-version-file: go.mod`; also remove the `golang-version` Renovate customManager

### Mutation testing (only when enabled in Step 1)

1. Splice the `mutation-test` job from `blocks/mutest.yml` into `ci.yml` at its marker.
2. Replace the `[MUTEST: insert mutation-testing region here]` marker in `.githooks/pre-push` with the marked region from `blocks/mutest.yml`.
3. Add the `mutest`, `mutest:all`, and `mutest:install` tasks from `blocks/mutest.yml` to `Taskfile.yml`.
4. Add the mutest `customManager` and package rule from `blocks/mutest.yml` to `renovate.json`.
5. Resolve `{{MUTEST_VERSION}}` to a release tag; never substitute `@latest`.

When mutest is **disabled**, remove only these skill-owned artifacts: the mutation job,
the marked hook region, the mutation Taskfile section, and the mutest Renovate manager/rule.
Preserve existing user-owned mutest content and existing files that are correct.

Before enabling this blocking check, disclose that mutest is a v0.x tool with a small maintainer
base. Mitigations are the identical version pin in CI and Taskfile, `automerge: false`,
module checksum verification, `git push --no-verify` locally, and the PR-only scope.

### SHA-pinning third-party actions

After writing all workflow files, resolve every `uses:` line with a `# SHA-pin` trailing comment:

1. Extract the `owner/repo@tag` from the `uses:` value
2. Resolve to a commit SHA:
   ```bash
   gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
   ```
   For example: `gh api repos/arduino/setup-task/commits/v2 --jq '.sha'`
3. Rewrite the line: `uses: <owner>/<repo>@<sha40>  # <tag>`
   For example: `uses: arduino/setup-task@abc123...def456  # v2`

This applies to all non-`actions/*` action pins:
- `arduino/setup-task@v2` (ci.yml ×3, release-matrix ×2, release-goreleaser ×2)
- `trufflesecurity/trufflehog@v3.x.y` (ci.yml ×1)
- `softprops/action-gh-release@v3` (release-matrix ×1)
- `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`, `docker/login-action@v4` (release-goreleaser ×1 each)
- `goreleaser/goreleaser-action@v7` (release-goreleaser ×1)

Renovate will update the SHA automatically when it detects a new release, matching the `# vX.Y.Z` comment tag.

## Step 6 — Verify

After writing all files, run this mental dry-run checklist:

- [ ] Every `task <name>` in ci.yml has a matching task in `Taskfile.yml`
- [ ] `task build:frontend` only appears when Frontend+Embed block is active
- [ ] `{{PROJECT}}`, `{{MODULE}}`, `{{DOCKER_IMAGE}}` all substituted (no raw `{{` in output)
- [ ] Pinned versions match Renovate customManager regex patterns in `renovate.json` (4 base managers; the opt-in mutest block adds the fifth)
- [ ] `golangci-lint version` in ci.yml matches version in `Taskfile.yml` (if locally installed)
- [ ] `CGO_ENABLED=1` only on the `test` job (race detector needs it)
- [ ] Release workflow (matrix): `verify` gates `build`, `build` gates `publish` (single publisher eliminates parallel release-API race)
- [ ] `.govulncheck-ignore` exists and is referenced by the govulncheck gate in ci.yml
- [ ] `fetch-depth: 0` on the secret-detection job (TruffleHog needs full history)
- [ ] Action versions are consistent: `checkout@v6`, `setup-go@v6` (with `cache: true`),
      `setup-node@v6`, `upload-artifact@v7`, `download-artifact@v8`, docker actions `@v4`, `goreleaser-action@v7`
- [ ] `git ls-files cmd/` returns hits — binary entry point is tracked
- [ ] `git ls-files testdata/` returns all required test fixtures (if testdata/ exists)
- [ ] golangci config loads cleanly — substitute `{{MODULE}}` and run `golangci-lint config verify .golangci.yml` (or `golangci-lint run --issues-exit-code=0` on a minimal test); must NOT error with "is a formatter" or similar
- [ ] No `${{ github.* }}` or `${{ matrix.* }}` expressions appear inside any `run:` block in release workflows (all routed via `env:`)
- [ ] Every non-`actions/*` `uses:` line is pinned to a 40-hex commit SHA with a `# vX.Y.Z` trailing comment
- [ ] No `GO_VERSION` env var in any workflow — all `setup-go` steps use `go-version-file: go.mod`
- [ ] `ci.yml` has a `concurrency: cancel-in-progress` block (absent from release workflows)
- [ ] govulncheck v1.4.0 warning comment is above the `# renovate:` line in `ci.yml`
- [ ] Every comment-supporting generated file has `# generated by go-github-pipelines v<version>` as first line (or second line for shell scripts after shebang)
- [ ] `go.mod` uses `go 1.X` plus `toolchain go1.X.Y` on separate lines (never `go 1.X.Y`), and the user confirmed the diff before the edit
- [ ] `go mod tidy`, `go build ./...`, and `go test ./...` pass after a Go-version update; no generated CI is left on a red build
- [ ] `.golangci.yml` has no `run.go`, and no workflow contains `GO_VERSION`
- [ ] `.githooks/pre-commit` and `.githooks/pre-push` exist, are executable, and `install-hooks` is present in `Taskfile.yml` (add only missing skill-owned tasks to an existing Taskfile)
- [ ] `bash -n .githooks/pre-commit && bash -n .githooks/pre-push` passes
- [ ] If mutest is off, no mutation job, mutation Taskfile section, mutest Renovate manager/rules, or mutest markers remain; remove the pre-push insertion marker too, while preserving user-owned existing content
- [ ] If mutest is on, its job has `if: github.event_name == 'pull_request'`, `needs: test`, `fetch-depth: 0`, `timeout-minutes`, and `set -euo pipefail`
- [ ] `${{ github.base_ref }}` appears only under `env:` and never inside a `run:` block
- [ ] Mutest version is identical in CI and Taskfile, with the `# renovate:` annotation immediately above each install line

## Key Decisions Baked In

| Pattern | Choice | Why |
|---|---|---|
| Step runner | Taskfile | Local/CI parity; consistent across all 5 projects |
| golangci-lint | `go install` pinned | Exact local/CI parity via Taskfile |
| Coverage gate | Per-file 80% default via `check-coverage.sh` | Catches low-coverage new files; total% can hide it. Per-function (strictest) and total also available as explicit modes. |
| Coverage service | Artifact upload only | No external service dependency (Codecov not used) |
| Build step | Real `go build` | `go build -n` (dry-run) misses linker errors |
| Vuln scanner | govulncheck + ignore-list gate | Language-aware; ignores unfixable CVEs safely |
| Secret scan | TruffleHog `--only-verified` | Low false-positive rate; runs on full history |
| Release | GoReleaser `dockers_v2` | Single multi-arch image; modern API |
| Deps | Renovate (self-hosted) | Handles everything: Go modules, actions, tools |
| Action pinning | Official `actions/*`: major-version tags; Third-party: SHA-pins + Renovate comment | SHA-pins are immutable (tags can move); Renovate maintains SHAs automatically |
| Go version | Newest stable, written as `go 1.X` + `toolchain go1.X.Y` after diff/confirmation | `setup-go` reads `go.mod`; the toolchain pin keeps CI reproducible without a `GO_VERSION` source |
| Git hooks | Always generated, inert until `task install-hooks` | Local format/lint parity without changing a clone's hook configuration automatically |
| Mutation testing | Opt-in, PR-only, diff-scoped mutest with threshold 0 | Catches boundary/equality gaps while avoiding legacy-code and full-module runtime costs |
