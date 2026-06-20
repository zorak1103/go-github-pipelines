# go-github-pipelines

Claude Code plugin providing the `building-go-github-pipelines` skill — generates GitHub Actions CI/CD pipelines for Go projects from versioned templates. Patterns distilled from five production repos: ha-mcp, dlia, notebook, bka-go, car-check.

## Releasing a new version

1. Bump `version` in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit: `chore: bump version to X.Y.Z`
3. Tag: `git tag vX.Y.Z`
4. Push commits and tag: `git push && git push origin vX.Y.Z`

Semver rules: `patch` for bug fixes only, `minor` for new template features or new skill options, `major` for breaking changes to generated output structure or skill behaviour.

Users update with: `/plugins update go-github-pipelines`

## Improving the skill from real-world findings

When a skill usage session surfaces issues, collect them in `temp/findings.md`, then:

1. `/superpowers:brainstorming` — resolve calibration decisions (coverage strictness, linter profiles, etc.) with the user before touching code
2. `writing-plans` skill — task-by-task implementation plan
3. `subagent-driven-development` skill — execute with fresh subagent per task + per-task review
4. Merge locally, bump version, tag, push

`temp/` is gitignored — safe for scratch work.

## Template mechanics

### Placeholder syntax (three distinct systems, do not confuse)

| Syntax | Owner | Rule |
|---|---|---|
| `{{UPPERCASE_SNAKE}}` | This skill | **Substitute** with actual value when generating |
| `{{.CamelCase}}` | GoReleaser `text/template` | **Leave as-is** in `.goreleaser.yaml` |
| `${{ expression }}` | GitHub Actions | **Leave as-is** in workflow YAML |

Never substitute inside `${{ }}` or `{{.Variable}}`.

### Profile markers in golangci.yml.tmpl

Two linters are marked `# profile:service-only` — they should be removed for CLI projects at generation time:
- `wrapcheck` — errors from external packages must be wrapped (too aggressive for CLIs)
- `noctx` — HTTP requests without context (CLIs often have no HTTP server)

The complexity thresholds have `# onboarding: N` comments showing the relaxed values to use when a project is being bootstrapped without an existing strict `.golangci.yml`.

### SHA-pin markers in workflow templates

Third-party action `uses:` lines carry a `# SHA-pin` trailing comment. At generation time the skill resolves each tag to a commit SHA:

```bash
gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
```

Then rewrites: `uses: owner/action@<sha40>  # <tag>`

Renovate tracks the SHA via the `# vX.Y.Z` comment and keeps it updated. **Do not remove these markers** — without them the generator will leave tag-pinned third-party actions (supply-chain risk).

Current third-party action pins that carry `# SHA-pin`:
- `arduino/setup-task@v2` — ci.yml (×3), release-matrix (×2), release-goreleaser (×2)
- `trufflesecurity/trufflehog@v3.x.y` — ci.yml (×1)
- `softprops/action-gh-release@v3` — release-matrix (×1)
- `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`, `docker/login-action@v4` — release-goreleaser (×1 each)
- `goreleaser/goreleaser-action@v7` — release-goreleaser (×1)

Official `actions/*` pins (checkout, setup-go, upload-artifact, setup-node) stay on major-version tags — no SHA-pin needed.

## Template-specific invariants

### golangci.yml.tmpl — golangci-lint v2 schema

The file declares `version: "2"`. v2 schema has breaking differences from v1:

- Settings must be **nested under `linters:`** as `linters.settings:` — the old top-level `linters-settings:` key is **silently ignored** in v2, so threshold violations go undetected.
- `gofmt` and `goimports` are **formatters, not linters** in v2. They must appear under a top-level `formatters.enable:` block. Listing them under `linters.enable:` causes a hard error: `Error: gofmt is a formatter`.
- `wrapcheck.ignorePackageGlobs` uses `{{MODULE}}/*` (the full Go module path), not `{{DOCKER_USER}}/{{PROJECT}}/*` (which is a Docker image name, not a module path).

Verify after any edit:
```bash
# After substituting {{MODULE}} with a real module path:
golangci-lint config verify .golangci.yml
# Must not error with "is a formatter" or show zero-effect settings
```

### renovate.json.tmpl — current Renovate API

`customManagers` must use `managerFilePatterns` (not the old `fileMatch`), and regex values must be wrapped in `/regex/` delimiters:

```json
"managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/"]
```

Not:
```json
"fileMatch": ["\\.github/workflows/.*\\.ya?ml$"]
```

There are 5 `customManagers` entries; all must use the new format. Validate with:
```bash
npx --yes renovate-config-validator renovate.json
```

The `extra-toolchain.yml` block file also contains a commented-out example `customManager` snippet — keep it in sync with the current API format.

### ci.yml.tmpl — govulncheck exit-code gate

The govulncheck step must **not** use `|| true`. Exit codes:
- `0` = clean (no vulnerabilities)
- `3` = vulnerabilities found (handled by the ignore-list gate below)
- anything else = tool error (network failure, binary missing, parse error) → **hard fail**

Correct pattern:
```bash
govulncheck -json ./... > vulncheck_output.json 2>&1; GOVULN_EXIT=$?
if [ "$GOVULN_EXIT" -ne 0 ] && [ "$GOVULN_EXIT" -ne 3 ]; then
  echo "::error::govulncheck failed with exit code ${GOVULN_EXIT}"
  exit "$GOVULN_EXIT"
fi
```

### release-matrix.yml.tmpl — no expression injection in run: blocks

`${{ github.ref_name }}`, `${{ matrix.suffix }}`, `${{ matrix.ext }}` must be passed through `env:` and referenced as shell variables (`${REF_NAME}`, `${SUFFIX}`, `${EXT}`) in `run:` blocks. Direct interpolation allows tag-name injection.

`${{ matrix.* }}` in `with:` blocks (e.g. `softprops/action-gh-release` `files:`) is safe — `with:` is evaluated by the action, not the shell.

### check-coverage.sh — coverage modes

The script accepts a third argument: `per-file` (default), `per-function` (strictest), `total`.

- **per-file**: aggregates function data to file level via weighted statement average, reading the raw `.out` profile directly (not `go tool cover -func` output — those formats differ)
- **per-function**: checks each function row from `go tool cover -func` individually
- **total**: reads the `total:` line from `go tool cover -func`

The generated-file skip uses `[[ pat1 || pat2 ]] && continue` (single compound test) — not `[[ pat1 ]] || [[ pat2 ]] && continue`, which has a precedence bug that causes `*_gen.go` to not be skipped.

Test the script against mock data:
```bash
# Substitute {{MODULE}} first:
sed 's/{{MODULE}}/github.com\/user\/proj/g' \
  skills/building-go-github-pipelines/templates/check-coverage.sh > /tmp/cov.sh
chmod +x /tmp/cov.sh
bash -n /tmp/cov.sh   # syntax check
```

## Tool version locations

Versions live in two places — they must stay in sync so Renovate's customManagers can track them:

| Tool | Location in templates | Renovate annotation |
|---|---|---|
| Go | `ci.yml` env `GO_VERSION`, both release workflows | `# renovate: datasource=golang-version depName=golang` |
| golangci-lint | `ci.yml` `go install` step, both release workflows, `Taskfile.yml` | `# renovate: datasource=go depName=github.com/golangci/golangci-lint/v2` |
| govulncheck | `ci.yml` `go install` step | `# renovate: datasource=go depName=golang.org/x/vuln` |
| GoReleaser | `release-goreleaser.yml` `version:` field | `# renovate: datasource=github-releases depName=goreleaser/goreleaser` |
| TruffleHog | `ci.yml` `uses:` tag | `# renovate: datasource=github-releases depName=trufflesecurity/trufflehog` |

When bumping a tool version manually, update **all** occurrences across templates — Renovate handles future updates automatically via the annotations.

## Skill structure

```
skills/building-go-github-pipelines/
  SKILL.md                          ← skill instructions (user-facing; do not put dev notes here)
  templates/
    golangci.yml.tmpl               ← golangci-lint v2 config (~30 linters)
    renovate.json.tmpl              ← Renovate config (5 customManagers)
    check-coverage.sh               ← coverage gate (per-file/per-function/total)
    govulncheck-ignore.tmpl         ← CVE ignore-list (comment-only template)
    Taskfile.yml.tmpl               ← task runner (local/CI parity)
    Dockerfile.tmpl                 ← multi-stage Docker build (conditional)
    goreleaser.yaml.tmpl            ← GoReleaser config (conditional)
    workflows/
      ci.yml.tmpl                   ← CI: lint / test+coverage / build / govulncheck / secrets
      release-goreleaser.yml.tmpl   ← release via GoReleaser (Docker + binaries)
      release-matrix.yml.tmpl       ← release via matrix (binaries only, no Docker)
      renovate.yml.tmpl             ← Renovate trigger workflow
  blocks/
    extra-toolchain.yml             ← snippet: install external binary for tests
    frontend-embed.yml              ← snippet: Node.js build + go:embed
```

The `blocks/` files are instructional snippets inserted by the generator — they are not standalone workflow files. They contain commented-out `renovate.json` customManager examples that must stay in sync with the current Renovate API format.

## What not to change

- The `govulncheck` ignore-list gate pattern (compare found vs. ignored via `comm -23`) — this is intentional and correct
- `CGO_ENABLED=1` on the `test` job only (race detector requires cgo; build job intentionally uses `CGO_ENABLED=0`)
- `fetch-depth: 0` on the secret-detection job only (TruffleHog needs full git history; other jobs use shallow clone for speed)
- `go install` pinned for golangci-lint (not `golangci-lint-action` — exact version parity between local and CI is the goal)
- Artifact upload instead of Codecov (no external service dependency is a deliberate choice)
