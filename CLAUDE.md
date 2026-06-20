# go-github-pipelines

Claude Code plugin providing the `building-go-github-pipelines` skill — generates GitHub Actions CI/CD pipelines for Go projects from versioned templates.

## Releasing a new version

1. Bump `version` in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit: `chore: bump version to X.Y.Z`
3. Tag: `git tag vX.Y.Z`
4. Push commits and tag: `git push && git push origin vX.Y.Z`

Use semver: `patch` for bug fixes only, `minor` for new capability (new template features, new skill options), `major` for breaking changes to skill behaviour or generated output structure.

Users update with: `/plugins update go-github-pipelines`

## Improving the skill from real-world findings

When a skill usage session surfaces issues, collect them in `temp/findings.md` and then:

1. `/superpowers:brainstorming` — turn findings into a design; resolve calibration decisions (coverage gate strictness, linter profiles, etc.) with the user before touching code
2. `writing-plans` skill — produce a task-by-task implementation plan
3. `subagent-driven-development` skill — execute the plan with fresh subagent per task + per-task review
4. Merge locally, bump version, tag, push

## Skill structure

```
skills/building-go-github-pipelines/
  SKILL.md                        ← skill instructions (read by Claude when invoked)
  templates/
    golangci.yml.tmpl             ← golangci-lint v2 config
    renovate.json.tmpl            ← Renovate Bot config
    check-coverage.sh             ← coverage gate script (modes: per-file/per-function/total)
    govulncheck-ignore.tmpl       ← CVE ignore-list template
    Taskfile.yml.tmpl             ← Taskfile for local/CI parity
    Dockerfile.tmpl               ← multi-stage Docker build
    goreleaser.yaml.tmpl          ← GoReleaser config
    workflows/
      ci.yml.tmpl                 ← CI pipeline (lint/test/build/govulncheck/secret-scan)
      release-goreleaser.yml.tmpl ← GoReleaser release workflow
      release-matrix.yml.tmpl    ← manual matrix release (binary-only)
      renovate.yml.tmpl           ← Renovate workflow
  blocks/
    extra-toolchain.yml           ← block for external binary test deps
    frontend-embed.yml            ← block for frontend + go:embed projects
```
