#!/usr/bin/env bash
# sanity_applications.sh - Fast sanity checks on ArgoCD Application manifests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"

log_section "🏥 Starting Application Sanity Checks"

check_required_tools yq find

OUT_DIR="${OUT_DIR:-out}"
JUNIT_FILE="${OUT_DIR}/sanity-junit.xml"
START_TIME=$(date +%s)

TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "sanity"

log_subsection "🔍 Discovering Application manifests"
mapfile -d "" APP_FILES < <(find "$COMPONENTS_DIR" -name application.yml -print0 2>/dev/null || true)

if [ ${#APP_FILES[@]} -eq 0 ]; then
  log_warning "No application.yml files found under ${COMPONENTS_DIR}/"
fi

# Check 1: Missing metadata.name
log_subsection "🧾 Check 1: Validating metadata.name exists"
MISSING_NAMES=0
for f in "${APP_FILES[@]}"; do
  name="$(get_app_metadata "$f" "metadata.name")"
  if [ -z "$name" ]; then
    log_error "Missing metadata.name in: $f"
    MISSING_NAMES=$((MISSING_NAMES + 1))
  fi
done

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ "$MISSING_NAMES" -gt 0 ]; then
  add_junit_test "$JUNIT_FILE" "sanity-missing-names" "failed" "Found $MISSING_NAMES file(s) missing metadata.name"
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  EXIT_CODE=1
else
  add_junit_test "$JUNIT_FILE" "sanity-missing-names" "passed"
  log_success "All application.yml files have metadata.name"
fi

# Check 2: Duplicate Application names
log_subsection "📋 Check 2: Checking for duplicate Application names"
declare -A NAME_TO_FILE=()
DUPLICATES=0

for f in "${APP_FILES[@]}"; do
  name="$(get_app_metadata "$f" "metadata.name")"
  [ -z "$name" ] && continue
  if [[ -n "${NAME_TO_FILE[$name]:-}" ]]; then
    log_error "Duplicate Application name '$name' found in:"
    log_error "  - ${NAME_TO_FILE[$name]}"
    log_error "  - $f"
    DUPLICATES=$((DUPLICATES + 1))
  else
    NAME_TO_FILE["$name"]="$f"
  fi
done

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ "$DUPLICATES" -gt 0 ]; then
  add_junit_test "$JUNIT_FILE" "sanity-duplicate-names" "failed" "Found $DUPLICATES duplicate Application name(s)"
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  EXIT_CODE=1
else
  add_junit_test "$JUNIT_FILE" "sanity-duplicate-names" "passed"
  log_success "No duplicate Application names detected"
fi

# Check 3: application.yaml (wrong extension)
log_subsection "📎 Check 3: Preventing application.yaml usage"
WRONG_EXT=0
while IFS= read -r -d '' f; do
  log_error "Wrong extension detected (must be application.yml): $f"
  WRONG_EXT=$((WRONG_EXT + 1))
done < <(find "$COMPONENTS_DIR" -name application.yaml -print0 2>/dev/null || true)

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ "$WRONG_EXT" -gt 0 ]; then
  add_junit_test "$JUNIT_FILE" "sanity-wrong-extension" "failed" "Found $WRONG_EXT file(s) named application.yaml"
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  EXIT_CODE=1
else
  add_junit_test "$JUNIT_FILE" "sanity-wrong-extension" "passed"
  log_success "No application.yaml files detected"
fi

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "SANITY CHECKS PASSED"
else
  log_error "SANITY CHECKS FAILED"
fi

exit $EXIT_CODE
