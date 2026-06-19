#!/usr/bin/env bash
# check-coverage.sh — Per-file coverage enforcement
# Usage: ./scripts/check-coverage.sh <coverage.out> <threshold>
# Example: ./scripts/check-coverage.sh coverage.out 80
#
# Honors // coverage-exempt: comments at the top of a file to skip enforcement.
# Skips test files, generated files, and files with no testable statements.

set -euo pipefail

COVERAGE_FILE="${1:-coverage.out}"
THRESHOLD="${2:-80}"
MODULE="{{MODULE}}"

if [ ! -f "$COVERAGE_FILE" ]; then
  echo "ERROR: Coverage file not found: $COVERAGE_FILE"
  exit 1
fi

echo "Checking per-file coverage (threshold: ${THRESHOLD}%)"
echo ""

FAILED=0
SKIPPED=0
PASSED=0

while IFS= read -r line; do
  # Parse: github.com/org/project/pkg/file.go:line:col  statements  coverage%
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

  # Skip files with 0 statements (empty, interfaces-only, etc.)
  statements=$(echo "$line" | awk '{print $2}')
  [[ "$statements" == "0" ]] && { ((SKIPPED++)) || true; continue; }

  # Honor // coverage-exempt: comment in source file
  if [ -f "$rel_path" ] && grep -q "// coverage-exempt:" "$rel_path" 2>/dev/null; then
    echo "  EXEMPT  $rel_path"
    ((SKIPPED++)) || true
    continue
  fi

  # Check coverage
  if awk "BEGIN { exit ($coverage < $THRESHOLD) ? 0 : 1 }"; then
    echo "  FAIL    ${rel_path} — ${coverage}% (need ${THRESHOLD}%)"
    ((FAILED++)) || true
  else
    ((PASSED++)) || true
  fi
done < <(go tool cover -func="$COVERAGE_FILE")

echo ""
echo "Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "ERROR: ${FAILED} file(s) below ${THRESHOLD}% coverage."
  echo "Add tests or mark intentionally-exempt files with: // coverage-exempt: <reason>"
  exit 1
fi

echo "All files meet the ${THRESHOLD}% coverage threshold."
