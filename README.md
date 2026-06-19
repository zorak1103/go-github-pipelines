# go-github-pipelines

A composable Claude Code skill that assembles production-grade GitHub Actions CI/CD
pipelines for Go projects — from a bare repo to a fully wired setup in one step.

## What it does

Inspects a Go project and generates a self-consistent set of workflows and companion
files, combining the best patterns learned across multiple production repos:

| Always included | Conditional |
|---|---|
| CI: lint, test, build, govulncheck, secret scanning | Frontend + `go:embed` (Node, npm cache) |
| Per-file 80% coverage gate | Release via GoReleaser (`dockers_v2`) |
| Renovate with customManager auto-updates | Release via manual matrix (binary-only) |
| `.golangci.yml` (~30 linters, v2 schema) | Docker runtime image |
| `scripts/check-coverage.sh` | Extra toolchain (e.g. Typst, Pandoc) |
| `.govulncheck-ignore` gate | |

## Key decisions baked in

- **golangci-lint** installed via `go install @pinned` for exact local/CI parity
- **govulncheck** with an ignore-list gate for unfixable CVEs (not just `|| true`)
- **TruffleHog** secret scanning on full git history (`--only-verified`)
- **GoReleaser `dockers_v2`** — single multi-arch image, not per-arch + manifest
- **Per-file** 80% coverage (not total %) — catches low-coverage new code
- **Renovate** self-hosted with `customManagers` that track pinned `go install` versions
- **Release re-verify** — lint+test gate before publishing, even on tag pushes
- Artifact-only coverage (no Codecov dependency)

## Install

```bash
claude plugin install github:zorak1103/go-github-pipelines
```

## Usage

Mention setting up or updating a GitHub Actions pipeline for a Go project — the skill
auto-triggers. Claude will detect which blocks apply (frontend, Docker, extra toolchains)
and ask for your Docker Hub username before generating the files.

### Trigger examples

- "Set up GitHub Actions CI for this project"
- "Update our pipeline to use govulncheck with an ignore list"
- "Add secret scanning to our CI"
- "Upgrade from Dependabot to Renovate"
- "Our goreleaser config uses the legacy dockers format, fix it"

## Generated files

```
.github/workflows/
  ci.yml              — lint, test/coverage, build, govulncheck, TruffleHog
  release.yml         — verify + GoReleaser (or manual matrix)
  renovate.yml        — daily Renovate with config validator
.golangci.yml         — full linter config (v2 schema)
scripts/
  check-coverage.sh   — per-file 80% gate, honors // coverage-exempt:
.govulncheck-ignore   — CVE ignore-list (with docs)
renovate.json         — automerge rules + customManager regexes
Taskfile.yml          — build, test, lint, vulncheck tasks (if missing)
.goreleaser.yaml      — dockers_v2 multi-arch (if GoReleaser release)
Dockerfile            — alpine, non-root UID 1000 (if Docker)
```

## Pinned versions (Renovate-tracked)

| Tool | Version |
|---|---|
| Go | 1.26.4 |
| golangci-lint | v2.12.2 |
| govulncheck | v1.3.0 |
| GoReleaser | v2.16.0 |
| TruffleHog | v3.88.31 |

All versions are annotated with `# renovate:` comments and tracked by
`customManagers` in the generated `renovate.json`.

## License

MIT
