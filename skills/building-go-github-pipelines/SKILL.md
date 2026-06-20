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

## Step 2 — Block Inventory

### Always-On (every Go project)
- `ci.yml` — lint, test/coverage, build, govulncheck, secret-detection
- `renovate.yml` + `renovate.json` — daily dep updates via Renovate
- `.golangci.yml` — full ~30-linter config (v2 schema)
- `scripts/check-coverage.sh` — configurable coverage gate (per-file default, 80% threshold), honors `// coverage-exempt:`; modes: per-file (default), per-function (strictest), total
- `.govulncheck-ignore` — ignore-list for CVEs without fixes

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

**Golden rule:** Never emit a `task <name>` step without the corresponding task in `Taskfile.yml`.
Never emit `task build:frontend` without the Frontend+Embed block active.

**Integration tests:** If the project has a `//go:build integration` tag pattern or a
`test:integration` task, split the `test` job into `unit-test` + `integration-test` +
`coverage` jobs (bka-go pattern). The Extra-Toolchain block is often needed alongside this.

**Binary name:** Check `./cmd/*/` directories — the folder name is the binary name
(e.g. `./cmd/server/` → BINARY=`server`). Use PROJECT only as a fallback.

## Step 3 — Placeholders

| Placeholder | Source | Example |
|---|---|---|
| `{{MODULE}}` | `go.mod` first line | `github.com/zorak1103/ha-mcp` |
| `{{PROJECT}}` | Last path segment of MODULE | `ha-mcp` |
| `{{BINARY}}` | Check `./cmd/*/` dirs first; fall back to PROJECT | `ha-mcp` or `server` |
| `{{DOCKER_USER}}` | User-provided | `zorak1103` |
| `{{GITHUB_USER}}` | User-provided (same as DOCKER_USER unless they differ) | `zorak1103` |
| `{{DOCKER_IMAGE}}` | `{{DOCKER_USER}}/{{PROJECT}}` | `zorak1103/ha-mcp` |
| `{{GO_VERSION}}` | Latest stable Go (check golang.org/dl) | `1.26.4` |
| `{{GOLANGCI_VERSION}}` | Latest golangci-lint v2 | `v2.12.2` |
| `{{GOVULNCHECK_VERSION}}` | Latest govulncheck | `v1.3.0` |
| `{{GORELEASER_VERSION}}` | Latest goreleaser | `v2.16.0` |
| `{{TOOL_NAME}}` | External test tool name (Extra-Toolchain block) | `typst` |
| `{{TOOL_NAME_UPPER}}` | Uppercase of TOOL_NAME (for env var names) | `TYPST` |
| `{{TOOL_VERSION}}` | External tool version (Extra-Toolchain block) | `0.14.2` |
| `{{NODE_VERSION}}` | Node.js version (Frontend+Embed block) | `24` |

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

## Step 4 — Generate Files

Write these files (always-on first, then conditionals):

```
.github/
  workflows/
    ci.yml                        ← from templates/workflows/ci.yml.tmpl
    renovate.yml                  ← from templates/workflows/renovate.yml.tmpl
    release.yml                   ← from release-goreleaser or release-matrix tmpl
.golangci.yml                     ← from templates/golangci.yml.tmpl
scripts/
  check-coverage.sh               ← from templates/check-coverage.sh (chmod +x)
.govulncheck-ignore               ← from templates/govulncheck-ignore.tmpl
renovate.json                     ← from templates/renovate.json.tmpl
Taskfile.yml                      ← from templates/Taskfile.yml.tmpl (if missing)
.goreleaser.yaml                  ← from templates/goreleaser.yaml.tmpl (if GoReleaser)
Dockerfile                        ← from templates/Dockerfile.tmpl (if Docker)
```

Do NOT overwrite files that already exist and are correct — compare and upgrade instead.
Legacy pattern upgrades to always apply:
- `dockers:` + `docker_manifests:` → `dockers_v2:` in goreleaser config
- `golangci-lint-action` step → `go install` pinned step
- `govulncheck@latest` plain run → ignore-list gate
- `@main` action pins → versioned pins

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

## Step 5 — Verify

After writing all files, run this mental dry-run checklist:

- [ ] Every `task <name>` in ci.yml has a matching task in `Taskfile.yml`
- [ ] `task build:frontend` only appears when Frontend+Embed block is active
- [ ] `{{PROJECT}}`, `{{MODULE}}`, `{{DOCKER_IMAGE}}` all substituted (no raw `{{` in output)
- [ ] Pinned versions match Renovate customManager regex patterns in `renovate.json`
- [ ] `golangci-lint version` in ci.yml matches version in `Taskfile.yml` (if locally installed)
- [ ] `CGO_ENABLED=1` only on the `test` job (race detector needs it)
- [ ] Release workflow has a `verify` job that gates the `release` job
- [ ] `.govulncheck-ignore` exists and is referenced by the govulncheck gate in ci.yml
- [ ] `fetch-depth: 0` on the secret-detection job (TruffleHog needs full history)
- [ ] Action versions are consistent: `checkout@v6`, `setup-go@v6` (with `cache: true`),
      `setup-node@v6`, `upload-artifact@v7`, docker actions `@v4`, `goreleaser-action@v7`
- [ ] `git ls-files cmd/` returns hits — binary entry point is tracked
- [ ] `git ls-files testdata/` returns all required test fixtures (if testdata/ exists)
- [ ] golangci config loads cleanly — substitute `{{MODULE}}` and run `golangci-lint config verify .golangci.yml` (or `golangci-lint run --issues-exit-code=0` on a minimal test); must NOT error with "is a formatter" or similar
- [ ] No `${{ github.* }}` or `${{ matrix.* }}` expressions appear inside any `run:` block in release workflows (all routed via `env:`)
- [ ] Every non-`actions/*` `uses:` line is pinned to a 40-hex commit SHA with a `# vX.Y.Z` trailing comment

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
