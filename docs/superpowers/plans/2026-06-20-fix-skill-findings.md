# Fix building-go-github-pipelines skill from real-world findings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every issue found during the car-check pipeline session so the skill generates pipelines that work on the first run, are secure by default, and ramp linter strictness to the project's existing state.

**Architecture:** All changes are to the skill itself (templates + SKILL.md); no application code. Template fixes are direct rewrites of config snippets. SKILL.md updates add detection questions, SHA-pin instructions, and pre-flight checks. The coverage script gets a new `mode` argument (default `per-file`) without breaking existing call sites.

**Tech Stack:** YAML (golangci-lint v2, Renovate, GitHub Actions), Bash, golangci-lint v2, Renovate Bot, govulncheck

## Global Constraints

- All template files live in `skills/building-go-github-pipelines/templates/` and `skills/building-go-github-pipelines/templates/workflows/`
- `SKILL.md` is at `skills/building-go-github-pipelines/SKILL.md`
- Never break placeholder syntax: `{{UPPERCASE}}` = skill substitutes; `${{ }}` = GitHub Actions (leave as-is); `{{.CamelCase}}` = GoReleaser (leave as-is)
- Conventional commits format: `fix:` for bugs, `feat:` for new capability
- One commit per task — keeps bisection clean
- Do NOT install any npm packages globally; use `npx --yes` for one-shot validation

---

## Task 1: Fix golangci.yml.tmpl — v2 schema + calibration

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/golangci.yml.tmpl` (full rewrite)

**What this fixes:** A1 (linters-settings → linters.settings), A2 (gofmt/goimports as formatters), C2 (errcheck excludes + goconst + CLI profile markers), C3 (DOCKER_USER → MODULE in wrapcheck)

- [ ] **Step 1: Confirm the bug is present**

```bash
grep -n "linters-settings:" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
grep -n "gofmt\|goimports" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
grep -n "DOCKER_USER" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
```

Expected: line ~48 shows `linters-settings:` (wrong v1 key), lines ~39-40 show gofmt/goimports under `linters.enable`, line ~82 shows `{{DOCKER_USER}}`.

- [ ] **Step 2: Rewrite the template**

Replace the entire contents of `skills/building-go-github-pipelines/templates/golangci.yml.tmpl` with:

```yaml
version: "2"

run:
  timeout: 5m
  modules-download-mode: readonly

linters:
  enable:
    # Correctness
    - errcheck          # unchecked errors
    - govet             # vet checks (includes shadow)
    - staticcheck       # staticanalysis (SA, S, QF)
    - ineffassign       # ineffectual assignments
    - unused            # unused code

    # Security
    - gosec             # security issues (G001-G601)

    # Code quality
    - gocritic          # diagnostics and style suggestions
    - revive            # opinionated linter (replaces golint)
    - goconst           # repeated string literals
    - misspell          # spelling mistakes

    # Complexity (onboarding: raise to funlen:80/50, gocognit:30, gocyclo:20)
    - funlen            # function length
    - gocognit          # cognitive complexity
    - gocyclo           # cyclomatic complexity

    # Error handling
    - errorlint         # error wrapping issues
    - wrapcheck         # profile:service-only — errors from external packages must be wrapped

    # HTTP / Context
    - bodyclose         # http response body not closed
    - noctx             # profile:service-only — http requests without context

    # Miscellaneous
    - exhaustive        # missing enum cases in switch
    - nilerr            # nil returned when error is non-nil
    - unparam           # unused function parameters
    - prealloc          # slice preallocation opportunities

  settings:
    govet:
      enable:
        - shadow           # variable shadowing

    errcheck:
      exclude-functions:
        # CLI / logging patterns where ignoring errors is idiomatic
        - fmt.Fprint
        - fmt.Fprintln
        - fmt.Fprintf
        - (io.Closer).Close

    funlen:
      lines: 60            # onboarding: 80
      statements: 40       # onboarding: 50

    gocognit:
      min-complexity: 23   # onboarding: 30

    gocyclo:
      min-complexity: 15   # onboarding: 20

    goconst:
      min-occurrences: 5   # default 3 is too noisy for test fixtures

    gocritic:
      enabled-tags:
        - diagnostic
        - style
        - performance

    revive:
      rules:
        - name: exported
          arguments:
            - disableStutteringCheck

    gosec:
      excludes:
        - G104  # Errors unhandled (covered by errcheck)
        - G304  # File path provided as taint input (often intentional)

    wrapcheck:
      ignorePackageGlobs:
        - "{{MODULE}}/*"

formatters:
  enable:
    - gofmt
    - goimports

issues:
  exclude-rules:
    # Test files: relax rules that hurt test readability
    - path: "_test\\.go$"
      linters:
        - errcheck
        - gosec
        - gocritic
        - funlen
        - gocognit
        - govet
        - goconst
        - wrapcheck

    # Generated code
    - path: "(_gen|_generated)\\.go$"
      linters:
        - all

  # Maximum issues per linter (0 = unlimited)
  max-issues-per-linter: 0
  max-same-issues: 0
```

- [ ] **Step 3: Verify structural correctness**

```bash
grep -n "linters-settings:" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: no output (key is gone)

grep -n "linters.settings\|^  settings:" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: line showing "  settings:" nested under linters:

grep -n "formatters:" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: line with top-level formatters block

grep -n "gofmt\|goimports" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: lines under "formatters:" only, NOT under "linters:"

grep -n "DOCKER_USER" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: no output (gone)

grep -n "MODULE" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: {{MODULE}}/* in wrapcheck section

grep -n "profile:service-only\|profile:cli-drop\|errcheck\|goconst" skills/building-go-github-pipelines/templates/golangci.yml.tmpl
# Expected: profile:service-only on wrapcheck and noctx lines; errcheck.exclude-functions; goconst.min-occurrences: 5
```

- [ ] **Step 4: Commit**

```bash
git add skills/building-go-github-pipelines/templates/golangci.yml.tmpl
git commit -m "$(cat <<'EOF'
fix(skill): fix golangci v2 schema bugs and calibrate linter defaults

- Move linters-settings: (v1, silently ignored) to linters.settings:
  nested under linters: per golangci-lint v2 schema requirement
- Move gofmt/goimports to top-level formatters: block (v2 rejects
  formatters listed under linters.enable with a hard error)
- Add errcheck.exclude-functions for fmt.Fprint*/Close (idiomatic in CLIs)
- Set goconst.min-occurrences: 5 (default 3 generates noise in test fixtures)
- Mark wrapcheck and noctx as profile:service-only (dropped for CLIs)
- Add onboarding threshold hints in comments (funlen/gocognit/gocyclo)
- Fix wrapcheck.ignorePackageGlobs: {{DOCKER_USER}} → {{MODULE}}/*
EOF
)"
```

---

## Task 2: Fix renovate.json.tmpl — breaking changes + gitAuthor

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/renovate.json.tmpl` (targeted edits)

**What this fixes:** A3 (fileMatch → managerFilePatterns with /regex/ delimiters in all 5 customManagers), B2 (add gitAuthor)

- [ ] **Step 1: Confirm the bugs are present**

```bash
grep -n "fileMatch" skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: 5 occurrences on lines ~64, 74, 84, 94, 104

grep -n "gitAuthor" skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: no output (missing)
```

- [ ] **Step 2: Rewrite the template**

Replace the entire contents of `skills/building-go-github-pipelines/templates/renovate.json.tmpl` with:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":dependencyDashboard",
    ":semanticCommits",
    ":automergeMinor",
    "group:allNonMajor"
  ],
  "timezone": "Europe/Berlin",
  "schedule": ["before 6am"],
  "prConcurrentLimit": 5,
  "platformAutomerge": true,
  "gitAuthor": "{{GITHUB_USER}} <{{GITHUB_USER}}@users.noreply.github.com>",
  "vulnerabilityAlerts": {
    "enabled": true
  },
  "packageRules": [
    {
      "description": "Automerge minor and patch updates for Go modules",
      "matchManagers": ["gomod"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    },
    {
      "description": "Automerge minor and patch updates for GitHub Actions",
      "matchManagers": ["github-actions"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    },
    {
      "description": "Automerge minor and patch updates for npm",
      "matchManagers": ["npm"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    },
    {
      "description": "Automerge Dockerfile base image updates (minor/patch)",
      "matchManagers": ["dockerfile"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    },
    {
      "description": "Major updates require manual review",
      "matchUpdateTypes": ["major"],
      "automerge": false
    },
    {
      "description": "Pin golangci-lint in GitHub Actions as a go package",
      "matchManagers": ["custom.regex"],
      "matchPackageNames": ["github.com/golangci/golangci-lint/v2"],
      "automerge": true
    },
    {
      "description": "Pin govulncheck in GitHub Actions as a go package",
      "matchManagers": ["custom.regex"],
      "matchPackageNames": ["golang.org/x/vuln"],
      "automerge": true
    }
  ],
  "customManagers": [
    {
      "description": "Update Go version in CI workflows (Renovate annotation comment)",
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/"],
      "matchStrings": [
        "# renovate: datasource=golang-version depName=golang\\n\\s+GO_VERSION: \"(?<currentValue>[^\"]+)\""
      ],
      "datasourceTemplate": "golang-version",
      "depNameTemplate": "golang"
    },
    {
      "description": "Update golangci-lint installed via go install",
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/", "/Taskfile\\.yml$/"],
      "matchStrings": [
        "# renovate: datasource=go depName=github.com/golangci/golangci-lint/v2\\n.*golangci-lint@(?<currentValue>[^\\s\"]+)"
      ],
      "datasourceTemplate": "go",
      "depNameTemplate": "github.com/golangci/golangci-lint/v2"
    },
    {
      "description": "Update govulncheck installed via go install",
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/", "/Taskfile\\.yml$/"],
      "matchStrings": [
        "# renovate: datasource=go depName=golang.org/x/vuln\\n.*govulncheck@(?<currentValue>[^\\s\"]+)"
      ],
      "datasourceTemplate": "go",
      "depNameTemplate": "golang.org/x/vuln"
    },
    {
      "description": "Update TruffleHog action version",
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/"],
      "matchStrings": [
        "# renovate: datasource=github-releases depName=trufflesecurity/trufflehog\\n.*trufflesecurity/trufflehog@(?<currentValue>[^\\s]+)"
      ],
      "datasourceTemplate": "github-releases",
      "depNameTemplate": "trufflesecurity/trufflehog"
    },
    {
      "description": "Update GoReleaser version in workflows",
      "customType": "regex",
      "managerFilePatterns": ["/\\.github/workflows/.*\\.ya?ml$/"],
      "matchStrings": [
        "# renovate: datasource=github-releases depName=goreleaser/goreleaser\\n\\s+version: (?<currentValue>[^\\s\"]+)"
      ],
      "datasourceTemplate": "github-releases",
      "depNameTemplate": "goreleaser/goreleaser"
    }
  ]
}
```

- [ ] **Step 3: Verify**

```bash
grep -n "fileMatch" skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: no output (all gone)

grep -n "managerFilePatterns" skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: 5 occurrences

grep -n '"/\\.' skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: all regex values start with / and end with /

grep -n "gitAuthor" skills/building-go-github-pipelines/templates/renovate.json.tmpl
# Expected: line with {{GITHUB_USER}}
```

If `npx` is available, validate the config with a placeholder substituted:

```bash
sed 's/{{GITHUB_USER}}/testuser/g' skills/building-go-github-pipelines/templates/renovate.json.tmpl \
  | npx --yes renovate-config-validator --stdin 2>&1 | head -5
# Expected: no "fileMatch" migration warning, exit 0
```

- [ ] **Step 4: Commit**

```bash
git add skills/building-go-github-pipelines/templates/renovate.json.tmpl
git commit -m "$(cat <<'EOF'
fix(skill): migrate renovate.json to current Renovate API

- Replace fileMatch → managerFilePatterns in all 5 customManagers
- Wrap all regex values in /regex/ delimiters (Renovate requirement)
- Add gitAuthor field to prevent "Unverified" Mend identity commits
- Add {{GITHUB_USER}} placeholder for gitAuthor (new placeholder, see SKILL.md update in Task 7)
EOF
)"
```

---

## Task 3: Fix ci.yml.tmpl — govulncheck fail-open + SHA-pin markers

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl`

**What this fixes:** A4 (govulncheck fail-open `|| true`), B3 (SHA-pin markers for arduino/setup-task and trufflehog)

- [ ] **Step 1: Confirm the bugs**

```bash
grep -n "|| true" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# Expected: line ~170 with govulncheck ... 2>/dev/null || true

grep -n "arduino/setup-task\|trufflesecurity/trufflehog" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# Expected: tag-pinned (no SHA)
```

- [ ] **Step 2: Fix govulncheck fail-open (line ~170)**

In `skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl`, replace:

```yaml
      - name: Run govulncheck with ignore-list gate
        run: |
          govulncheck -json ./... > vulncheck_output.json 2>/dev/null || true
```

with:

```yaml
      - name: Run govulncheck with ignore-list gate
        run: |
          govulncheck -json ./... > vulncheck_output.json 2>&1; GOVULN_EXIT=$?
          # exit 0 = clean, exit 3 = vulnerabilities found (handled below), other = tool error
          if [ "$GOVULN_EXIT" -ne 0 ] && [ "$GOVULN_EXIT" -ne 3 ]; then
            echo "::error::govulncheck failed with exit code ${GOVULN_EXIT} (binary missing, network error, or parse failure)"
            exit "$GOVULN_EXIT"
          fi
```

- [ ] **Step 3: Add SHA-pin markers to arduino/setup-task (lines ~37, ~86, ~133)**

In `ci.yml.tmpl`, change every occurrence of:

```yaml
        uses: arduino/setup-task@v2
```

to:

```yaml
        uses: arduino/setup-task@v2  # SHA-pin
```

There are 3 occurrences in ci.yml.tmpl (lint job, test job, build job). Use replace-all.

- [ ] **Step 4: Add SHA-pin marker + Renovate annotation to trufflehog (line ~214)**

Replace:

```yaml
      - name: TruffleHog Secret Scan
        # Renovate auto-detects GitHub Actions uses: pins — no annotation needed
        uses: trufflesecurity/trufflehog@v3.88.31
```

with:

```yaml
      - name: TruffleHog Secret Scan
        # renovate: datasource=github-releases depName=trufflesecurity/trufflehog
        uses: trufflesecurity/trufflehog@v3.88.31  # SHA-pin
```

(The old comment said "no annotation needed" because it was tag-pinned; now that we'll SHA-pin it, Renovate needs the annotation to track the version from the comment.)

- [ ] **Step 5: Verify**

```bash
grep -n "|| true" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# Expected: no output (gone)

grep -n "GOVULN_EXIT" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# Expected: 3 occurrences (assignment, first if-check, second if-check... actually ~4)

grep -n "SHA-pin" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# Expected: 4 occurrences (3 arduino, 1 trufflehog)

grep -n "arduino/setup-task\|trufflehog" skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
# All should end with # SHA-pin
```

- [ ] **Step 6: Commit**

```bash
git add skills/building-go-github-pipelines/templates/workflows/ci.yml.tmpl
git commit -m "$(cat <<'EOF'
fix(skill): close govulncheck fail-open gate; mark third-party actions for SHA-pinning

- Capture govulncheck exit code explicitly: tool crash now hard-fails
  instead of silently reporting "no vulnerabilities found"
- exit 0 = clean, exit 3 = vulns (handled by ignore-list gate), other = hard fail
- Add # SHA-pin marker to arduino/setup-task@v2 (3 jobs) and trufflehog
- Add Renovate annotation to trufflehog (required when SHA-pinned)
EOF
)"
```

---

## Task 4: Fix release-matrix.yml.tmpl — shell injection + SHA-pin markers

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl`

**What this fixes:** B1 (expression injection: ref_name/suffix/ext via env:), B3 (SHA-pin markers for arduino/setup-task and softprops/action-gh-release)

- [ ] **Step 1: Confirm the bugs**

```bash
grep -n 'github.ref_name\|matrix.suffix\|matrix.ext' skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
# Expected: ${{ github.ref_name }}, ${{ matrix.suffix }}, ${{ matrix.ext }} inside a run: block (lines ~112-113)

grep -n "arduino/setup-task\|softprops/action-gh-release" skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
# Expected: tag-pinned, no SHA
```

- [ ] **Step 2: Fix the Build binary step (lines ~105-114)**

Replace:

```yaml
      - name: Build binary
        env:
          GOOS: ${{ matrix.goos }}
          GOARCH: ${{ matrix.goarch }}
          CGO_ENABLED: "0"
        run: |
          go build \
            -ldflags="-s -w -X {{MODULE}}/internal/version.Version=${{ github.ref_name }}" \
            -o {{BINARY}}-${{ matrix.suffix }}${{ matrix.ext || '' }} \
            ./cmd/{{BINARY}}/
```

with:

```yaml
      - name: Build binary
        env:
          GOOS: ${{ matrix.goos }}
          GOARCH: ${{ matrix.goarch }}
          CGO_ENABLED: "0"
          REF_NAME: ${{ github.ref_name }}
          SUFFIX: ${{ matrix.suffix }}
          EXT: ${{ matrix.ext || '' }}
        run: |
          go build \
            -ldflags="-s -w -X {{MODULE}}/internal/version.Version=${REF_NAME}" \
            -o "{{BINARY}}-${SUFFIX}${EXT}" \
            ./cmd/{{BINARY}}/
```

- [ ] **Step 3: Add SHA-pin markers**

Replace (line ~36 verify job, line ~95 release job):

```yaml
        uses: arduino/setup-task@v2
```

with:

```yaml
        uses: arduino/setup-task@v2  # SHA-pin
```

(2 occurrences — one in verify, one in release job)

Replace:

```yaml
        uses: softprops/action-gh-release@v3
```

with:

```yaml
        uses: softprops/action-gh-release@v3  # SHA-pin
```

- [ ] **Step 4: Verify**

```bash
grep -n 'github.ref_name\|matrix.suffix\|matrix.ext' skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
# Expected: only in the env: block now, NOT inside run:

grep -n 'REF_NAME\|SUFFIX\|EXT' skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
# Expected: in env: block and referenced as ${VAR} in run:

grep -n "SHA-pin" skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
# Expected: 3 occurrences (2x arduino, 1x softprops)
```

- [ ] **Step 5: Commit**

```bash
git add skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl
git commit -m "$(cat <<'EOF'
fix(skill): prevent shell injection in release-matrix and mark actions for SHA-pinning

- Route github.ref_name, matrix.suffix, matrix.ext through env: block
  so they are never interpolated directly into shell (prevents tag-name injection)
- Add # SHA-pin marker to arduino/setup-task@v2 (verify + release jobs)
- Add # SHA-pin marker to softprops/action-gh-release@v3
EOF
)"
```

---

## Task 5: Fix release-goreleaser.yml.tmpl — SHA-pin markers

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl`

**What this fixes:** B3 (SHA-pin markers for arduino/setup-task, docker actions, goreleaser-action)

- [ ] **Step 1: Confirm the bug**

```bash
grep -n "arduino/setup-task\|docker/setup-qemu-action\|docker/setup-buildx-action\|docker/login-action\|goreleaser/goreleaser-action" \
  skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl
# Expected: all tag-pinned, no SHA
```

- [ ] **Step 2: Add SHA-pin markers**

In `skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl`, add `  # SHA-pin` to the end of each of these `uses:` lines (there are 2 jobs, so arduino appears twice):

Change every instance of these lines by appending `  # SHA-pin`:

```
        uses: arduino/setup-task@v2
        uses: docker/setup-qemu-action@v4
        uses: docker/setup-buildx-action@v4
        uses: docker/login-action@v4
        uses: goreleaser/goreleaser-action@v7
```

Resulting in:

```yaml
        uses: arduino/setup-task@v2  # SHA-pin
        uses: docker/setup-qemu-action@v4  # SHA-pin
        uses: docker/setup-buildx-action@v4  # SHA-pin
        uses: docker/login-action@v4  # SHA-pin
        uses: goreleaser/goreleaser-action@v7  # SHA-pin
```

Note: `arduino/setup-task@v2` appears in both the verify job (~L40) and the release job (~L82) — both get the marker.

- [ ] **Step 3: Verify**

```bash
grep -n "SHA-pin" skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl
# Expected: 6 occurrences (2x arduino, 1x qemu, 1x buildx, 1x login, 1x goreleaser)

grep -n "uses:" skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl | grep -v "SHA-pin\|actions/"
# Expected: no output (every non-official-actions uses: now has # SHA-pin)
```

- [ ] **Step 4: Commit**

```bash
git add skills/building-go-github-pipelines/templates/workflows/release-goreleaser.yml.tmpl
git commit -m "$(cat <<'EOF'
fix(skill): mark all third-party actions in release-goreleaser for SHA-pinning

Supply-chain risk: tags can be moved to a different commit at any time.
SHA-pinned actions are immutable; Renovate updates the SHA automatically
when the # vX.Y.Z comment is present (added during generation per SKILL.md).
EOF
)"
```

---

## Task 6: Rewrite check-coverage.sh — configurable mode (default per-file)

**Files:**
- Modify: `skills/building-go-github-pipelines/templates/check-coverage.sh` (full rewrite)

**What this fixes:** C1 (add mode argument with per-file default; fix header mislabeling "per-file" when script is actually per-function; implement true per-file via weighted statement aggregation; add total mode)

- [ ] **Step 1: Confirm the current behavior**

```bash
head -5 skills/building-go-github-pipelines/templates/check-coverage.sh
# Expected: header says "Per-file coverage enforcement" but arg count shows $2=threshold with no $3

grep -n "go tool cover" skills/building-go-github-pipelines/templates/check-coverage.sh
# Expected: single-pass loop checking each function row individually (per-function behavior)
```

- [ ] **Step 2: Rewrite the script**

Replace the entire contents of `skills/building-go-github-pipelines/templates/check-coverage.sh` with:

```bash
#!/usr/bin/env bash
# check-coverage.sh — Coverage enforcement with configurable granularity
# Usage: ./scripts/check-coverage.sh <coverage.out> <threshold> [mode]
#
# Modes:
#   per-file      (default) — each source file's weighted-average coverage must meet threshold
#   per-function  (strictest) — every individual function must meet the threshold
#   total         — the whole project total must meet threshold
#
# Honors // coverage-exempt: comments at the top of a file to skip enforcement.
# Skips _test.go, _gen.go, _generated.go, and entries with 0 statements.

set -euo pipefail

COVERAGE_FILE="${1:-coverage.out}"
THRESHOLD="${2:-80}"
MODE="${3:-per-file}"
MODULE="{{MODULE}}"

if [ ! -f "$COVERAGE_FILE" ]; then
  echo "ERROR: Coverage file not found: $COVERAGE_FILE"
  exit 1
fi

case "$MODE" in
  per-file|per-function|total) ;;
  *)
    echo "ERROR: Unknown mode '$MODE'. Valid: per-file, per-function, total"
    exit 1
    ;;
esac

echo "Checking ${MODE} coverage (threshold: ${THRESHOLD}%)"
echo ""

# ── helpers ───────────────────────────────────────────────────────────────────

is_exempt() {
  local path="$1"
  [ -f "$path" ] && grep -q "// coverage-exempt:" "$path" 2>/dev/null
}

# ── total mode ────────────────────────────────────────────────────────────────

if [ "$MODE" = "total" ]; then
  total_line=$(go tool cover -func="$COVERAGE_FILE" | grep '^total:')
  total_cov=$(echo "$total_line" | awk '{print $3}' | tr -d '%')
  echo "  Total coverage: ${total_cov}%"
  echo ""
  if awk "BEGIN { exit ($total_cov < $THRESHOLD) ? 0 : 1 }"; then
    echo "ERROR: Total coverage ${total_cov}% is below ${THRESHOLD}%."
    echo "Add tests to bring coverage up."
    exit 1
  fi
  echo "Total coverage meets the ${THRESHOLD}% threshold."
  exit 0
fi

# ── per-function and per-file modes ───────────────────────────────────────────

FAILED=0
SKIPPED=0
PASSED=0

if [ "$MODE" = "per-function" ]; then
  # Strictest variant: every function row must individually meet the threshold.
  while IFS= read -r line; do
    file_path=$(echo "$line" | awk '{print $1}' | sed 's/:.*$//')
    coverage=$(echo "$line" | awk '{print $3}' | tr -d '%')

    # Skip "total:" summary line
    [[ "$file_path" == "total:" ]] && continue

    # Strip module prefix to get relative path
    rel_path="${file_path#${MODULE}/}"

    # Skip test files
    [[ "$rel_path" == *_test.go ]] && continue

    # Skip generated files
    [[ "$rel_path" == *_gen.go ]] || [[ "$rel_path" == *_generated.go ]] && continue

    # Skip entries with 0 statements (empty files, interface-only, etc.)
    statements=$(echo "$line" | awk '{print $2}')
    [[ "$statements" == "0" ]] && { ((SKIPPED++)) || true; continue; }

    # Honor // coverage-exempt: in source file
    if is_exempt "$rel_path"; then
      echo "  EXEMPT  $rel_path"
      ((SKIPPED++)) || true
      continue
    fi

    if awk "BEGIN { exit ($coverage < $THRESHOLD) ? 0 : 1 }"; then
      echo "  FAIL    ${rel_path} — ${coverage}% (need ${THRESHOLD}%)"
      ((FAILED++)) || true
    else
      ((PASSED++)) || true
    fi
  done < <(go tool cover -func="$COVERAGE_FILE")

else
  # per-file: aggregate function-level data to file level via weighted statement average.
  # For each file: file_coverage = sum(stmts_i * cov_i) / sum(stmts_i)
  while IFS=$'\t' read -r rel_path file_cov; do
    [ -z "$rel_path" ] && continue

    if is_exempt "$rel_path"; then
      echo "  EXEMPT  $rel_path"
      ((SKIPPED++)) || true
      continue
    fi

    if awk "BEGIN { exit ($file_cov < $THRESHOLD) ? 0 : 1 }"; then
      echo "  FAIL    ${rel_path} — ${file_cov}% (need ${THRESHOLD}%)"
      ((FAILED++)) || true
    else
      ((PASSED++)) || true
    fi
  done < <(go tool cover -func="$COVERAGE_FILE" | awk \
    -v module="${MODULE}/" '
    /^total:/ { next }
    {
      # Field layout: module/path/file.go:line:col  <statements>  <coverage%>
      path = $1
      sub(/:[^:]+:[^:]+$/, "", path)   # strip :line:col
      sub(module, "", path)             # strip module prefix → relative path

      stmts = $2 + 0
      if (stmts == 0) next

      if (path ~ /_test\.go$/) next
      if (path ~ /(_gen|_generated)\.go$/) next

      cov = $3
      sub(/%$/, "", cov)
      cov = cov + 0

      total_stmts[path]   += stmts
      covered_stmts[path] += stmts * cov / 100.0
    }
    END {
      for (path in total_stmts) {
        if (total_stmts[path] == 0) next
        printf "%s\t%.1f\n", path, (covered_stmts[path] / total_stmts[path] * 100.0)
      }
    }')
fi

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  if [ "$MODE" = "per-function" ]; then
    echo "ERROR: ${FAILED} function(s) below ${THRESHOLD}% coverage."
  else
    echo "ERROR: ${FAILED} file(s) below ${THRESHOLD}% coverage."
  fi
  echo "Add tests or mark intentionally-exempt files with: // coverage-exempt: <reason>"
  exit 1
fi

if [ "$MODE" = "per-function" ]; then
  echo "All functions meet the ${THRESHOLD}% coverage threshold."
else
  echo "All files meet the ${THRESHOLD}% coverage threshold."
fi
```

- [ ] **Step 3: Test the script against mock coverage data**

Create a mock coverage file and test all three modes:

```bash
cat > /tmp/mock-coverage.out <<'EOF'
mode: set
github.com/testuser/myproject/cmd/main.go:10.2,12.1 5 1
github.com/testuser/myproject/cmd/main.go:14.2,16.1 3 0
github.com/testuser/myproject/pkg/service.go:20.2,25.1 10 9
github.com/testuser/myproject/pkg/service.go:30.2,32.1 2 2
github.com/testuser/myproject/pkg/service_test.go:40.2,42.1 3 3
EOF

# Patch MODULE for the test run (or use a copy)
sed 's/{{MODULE}}/github.com\/testuser\/myproject/g' \
  skills/building-go-github-pipelines/templates/check-coverage.sh > /tmp/test-coverage.sh
chmod +x /tmp/test-coverage.sh

# total mode: should pass (main 62.5%, service 100%, test skipped)
/tmp/test-coverage.sh /tmp/mock-coverage.out 60 total
# Expected: "Total coverage meets the 60% threshold." (exit 0)

# per-file mode: main.go is 62.5% (5 stmts, 5×1/5=1 covered, wait let me recalculate)
# cmd/main.go: 5 stmts at 100% (1 covered) + 3 stmts at 0% (0 covered) = 5/8 = 62.5%
# pkg/service.go: 10 stmts at 90% + 2 stmts at 100% = 11/12 = 91.7%
/tmp/test-coverage.sh /tmp/mock-coverage.out 60 per-file
# Expected: both files pass at 60% threshold (exit 0)

/tmp/test-coverage.sh /tmp/mock-coverage.out 70 per-file
# Expected: cmd/main.go FAIL at 62.5% (exit 1)

# per-function mode: first function in main.go is 100%, second is 0%
/tmp/test-coverage.sh /tmp/mock-coverage.out 50 per-function
# Expected: one function FAIL (0% < 50%) → exit 1

rm /tmp/mock-coverage.out /tmp/test-coverage.sh
```

- [ ] **Step 4: Verify the script is valid bash**

```bash
bash -n skills/building-go-github-pipelines/templates/check-coverage.sh
# Expected: no output (no syntax errors)
```

- [ ] **Step 5: Commit**

```bash
git add skills/building-go-github-pipelines/templates/check-coverage.sh
git commit -m "$(cat <<'EOF'
feat(skill): make coverage gate configurable with per-file default

Add optional third argument MODE (per-file|per-function|total).
Default changes from per-function (the hidden behavior) to per-file.

- per-file (default): weighted statement average per source file
  Realistic for new projects; tolerates low-coverage entrypoints
  without requiring blanket exemptions
- per-function (strictest): original behavior, now explicit
  Every function must individually meet the threshold
- total: whole-project total must meet threshold
  Useful as a safety net alongside per-file

Fix header comment mislabeling (was "per-file", behavior was per-function).
Existing call sites (check-coverage.sh coverage.out 80) still work — mode
defaults to per-file and threshold arg position is unchanged.
EOF
)"
```

---

## Task 7: Update SKILL.md — docs for all changes

**Files:**
- Modify: `skills/building-go-github-pipelines/SKILL.md`

**What this fixes:** C1 (fix per-file/per-function doc drift), C2 (add project-type + strictness detection in Step 1), C4 (add pre-flight git ls-files checks), D (GITHUB_USER placeholder, SHA-pin instruction in Step 4, Step 5 verify items, Key Decisions updates)

- [ ] **Step 1: Add `{{GITHUB_USER}}` to Step 1 Detect and Step 3 Placeholders**

In Step 1, `SKILL.md` currently asks:
> Ask the user for:
> - `{{DOCKER_USER}}` — Docker Hub username (e.g. `zorak1103`)
> - Release style: ...

Replace that `Ask the user for:` block with:

```markdown
Ask the user for:
- `{{GITHUB_USER}}` — GitHub username (e.g. `zorak1103`). Used for Renovate gitAuthor and wrapcheck module glob.
- `{{DOCKER_USER}}` — Docker Hub username (same as `{{GITHUB_USER}}` in most cases; confirm if they differ)
- Release style: **GoReleaser** (default) or **manual matrix** (no Docker, just binaries)?
- Does this project publish to Docker Hub? (sets whether release+Docker block is included)

Also detect:
- **Project type** — Check `./cmd/*/` and `./main.go`: if there is a `cmd/` binary entry point with no HTTP server / gRPC handler patterns, treat as **CLI**. Otherwise treat as **service/library**. For CLI projects, remove the `profile:service-only` linters from `.golangci.yml` (wrapcheck, noctx).
- **Existing golangci config** — If `.golangci.yml` already exists and is non-trivial (has `linters.enable` with 5+ linters), preserve its rigor (use strict thresholds from the template). If absent or minimal (e.g., only `go vet`), ask the user: "Start with strict thresholds (funlen:60/40, gocognit:23, gocyclo:15) or onboarding thresholds (funlen:80/50, gocognit:30, gocyclo:20)?" Use the onboarding values to avoid 365-findings-on-first-run.
```

- [ ] **Step 2: Add pre-flight checks to Step 1 Detect**

After the `Read these files/paths and record what exists:` table in Step 1, add a new sub-section:

```markdown
### Pre-flight checks (run before generating any files)

Before writing any output, verify the project is in a state that CI can run successfully:

| Check | Command | Action if fails |
|---|---|---|
| Binary entry point is committed | `git ls-files cmd/` | Warn: "cmd/ is not tracked by git — check .gitignore for patterns that match source directories" |
| Test fixtures are committed | `git ls-files testdata/` | Warn: "testdata/ is not tracked — fixtures may be gitignored; tests may pass locally but fail on CI" |
| .gitignore doesn't shadow sources | `grep -E '^(cmd|internal|pkg|testdata)' .gitignore` | Warn if any match: "Pattern may gitignore source code — check immediately" |
```

- [ ] **Step 3: Add `{{GITHUB_USER}}` to Step 3 Placeholders table**

In the placeholders table, add a row after `{{DOCKER_USER}}`:

```markdown
| `{{GITHUB_USER}}` | User-provided (same as DOCKER_USER unless they differ) | `zorak1103` |
```

Also add a note after the table:

```markdown
**Profile selection:** After placeholder substitution, apply the project profile:
- **CLI projects**: remove linters marked `# profile:service-only` from `linters.enable` in `.golangci.yml` (wrapcheck, noctx)
- **Onboarding strictness**: if user chose onboarding thresholds, update the funlen/gocognit/gocyclo settings in `.golangci.yml` to the onboarding values noted in the template comments
```

- [ ] **Step 4: Add SHA-pin resolution instruction to Step 4 Generate**

At the end of the Step 4 Generate section, add:

```markdown
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
```

- [ ] **Step 5: Update Step 2 Block Inventory description for coverage script**

In Step 2, change:

```markdown
- `scripts/check-coverage.sh` — per-file 80% gate, honors `// coverage-exempt:`
```

to:

```markdown
- `scripts/check-coverage.sh` — configurable coverage gate (per-file default, 80% threshold), honors `// coverage-exempt:`; modes: per-file (default), per-function (strictest), total
```

- [ ] **Step 6: Add items to Step 5 Verify checklist**

In Step 5, add these items to the checklist:

```markdown
  - [ ] `git ls-files cmd/` returns hits — binary entry point is tracked
  - [ ] `git ls-files testdata/` returns all required test fixtures (if testdata/ exists)
  - [ ] golangci config loads cleanly — substitute `{{MODULE}}` and run `golangci-lint config verify .golangci.yml` (or `golangci-lint run --issues-exit-code=0` on a minimal test); must NOT error with "is a formatter" or similar
  - [ ] No `${{ github.* }}` or `${{ matrix.* }}` expressions appear inside any `run:` block in release workflows (all routed via `env:`)
  - [ ] Every non-`actions/*` `uses:` line is pinned to a 40-hex commit SHA with a `# vX.Y.Z` trailing comment
```

- [ ] **Step 7: Update Key Decisions table**

Change the `Coverage gate` row from:

```markdown
| Coverage gate | Per-file 80% via `check-coverage.sh` | Catches low-coverage new code; total% can hide it |
```

to:

```markdown
| Coverage gate | Per-file 80% default via `check-coverage.sh` | Catches low-coverage new files; total% can hide it. Per-function (strictest) and total also available as explicit modes. |
```

Change the `Action pinning` row from:

```markdown
| Action pinning | Major-version tags + Renovate | Balance stability and security |
```

to:

```markdown
| Action pinning | Official `actions/*`: major-version tags; Third-party: SHA-pins + Renovate comment | SHA-pins are immutable (tags can move); Renovate maintains SHAs automatically |
```

- [ ] **Step 8: Verify SKILL.md is complete and consistent**

```bash
grep -n "per-file\|per-function\|per-function" skills/building-go-github-pipelines/SKILL.md | head -20
# Expected: no remaining places that say "per-file" where the script actually did per-function

grep -n "GITHUB_USER" skills/building-go-github-pipelines/SKILL.md
# Expected: multiple hits — Step 1, Step 3 table, gitAuthor usage

grep -n "SHA-pin\|sha-pin\|commit SHA" skills/building-go-github-pipelines/SKILL.md
# Expected: SHA-pin resolution instruction in Step 4

grep -n "git ls-files" skills/building-go-github-pipelines/SKILL.md
# Expected: pre-flight table in Step 1 and/or Step 5 checklist

grep -n "profile:service-only\|CLI\|onboarding" skills/building-go-github-pipelines/SKILL.md
# Expected: project-type detection in Step 1, profile notes in Step 3
```

- [ ] **Step 9: Commit**

```bash
git add skills/building-go-github-pipelines/SKILL.md
git commit -m "$(cat <<'EOF'
docs(skill): update SKILL.md for all findings corrections

- Add {{GITHUB_USER}} placeholder (Step 1 + Step 3) for Renovate gitAuthor
- Add project-type detection (CLI vs service/library) in Step 1
  CLI projects drop profile:service-only linters (wrapcheck, noctx)
- Add strictness gate in Step 1: detect existing .golangci.yml;
  offer onboarding thresholds if project is new to strict linting
- Add pre-flight checks in Step 1 (git ls-files cmd/, testdata/, .gitignore scan)
- Add SHA-pin resolution instruction in Step 4 for all third-party actions
- Fix per-file vs per-function coverage doc drift (Step 2, Key Decisions)
- Add Step 5 verify items: golangci config verify, injection grep, SHA-pin check, git tracking
EOF
)"
```

---

## Final verification (cross-task)

After all 7 tasks are committed, run a final audit:

- [ ] **No regressions in template syntax**

```bash
# All {{PLACEHOLDER}} markers still intact (none accidentally substituted or mangled)
grep -rn "{{[A-Z_]*}}" skills/building-go-github-pipelines/templates/ | grep -v "{{MODULE}}\|{{PROJECT}}\|{{BINARY}}\|{{DOCKER_USER}}\|{{GITHUB_USER}}\|{{DOCKER_IMAGE}}\|{{GO_VERSION}}\|{{GOLANGCI_VERSION}}\|{{GOVULNCHECK_VERSION}}\|{{GORELEASER_VERSION}}\|{{TOOL_NAME}}\|{{TOOL_NAME_UPPER}}\|{{TOOL_VERSION}}\|{{NODE_VERSION}}"
# Expected: no output (no unknown placeholders)

# No linters-settings: top-level key remaining
grep -rn "^linters-settings:" skills/building-go-github-pipelines/
# Expected: no output

# No fileMatch in renovate templates
grep -rn '"fileMatch"' skills/building-go-github-pipelines/
# Expected: no output

# No || true on govulncheck
grep -rn "govulncheck.*|| true" skills/building-go-github-pipelines/
# Expected: no output

# No direct expression injection in release run: blocks
grep -A5 "run: |" skills/building-go-github-pipelines/templates/workflows/release-matrix.yml.tmpl | grep 'github\.\|matrix\.'
# Expected: no output (all such refs are now in env: blocks)
```

- [ ] **Count SHA-pin markers**

```bash
grep -rn "SHA-pin" skills/building-go-github-pipelines/templates/
# Expected: ci.yml.tmpl: 4, release-matrix.yml.tmpl: 3, release-goreleaser.yml.tmpl: 6
```

- [ ] **Script syntax check**

```bash
bash -n skills/building-go-github-pipelines/templates/check-coverage.sh
# Expected: no output
```
