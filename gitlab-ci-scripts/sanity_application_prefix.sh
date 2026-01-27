#!/usr/bin/env bash
# sanity_application_prefix.sh - Optional prefix validation for ArgoCD Application names

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"
NAME_PREFIX="${APP_NAME_PREFIX:-${GITOPS_APPLICATION_NAME_PREFIX:-}}"

if [ -z "$NAME_PREFIX" ]; then
  log_section "🔕 Skipping Application Prefix Check (APP_NAME_PREFIX is not set)"
  exit 0
fi

log_section "🏷️  Starting Application Prefix Check"

check_required_tools yq find

OUT_DIR="${OUT_DIR:-out}"
JUNIT_FILE="${OUT_DIR}/sanity-prefix-junit.xml"
START_TIME=$(date +%s)

TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "sanity-prefix"

log_subsection "🔍 Discovering Application manifests"
mapfile -d "" APP_FILES < <(find "$COMPONENTS_DIR" -name application.yml -print0 2>/dev/null || true)

if [ ${#APP_FILES[@]} -eq 0 ]; then
  log_warning "No application.yml files found under ${COMPONENTS_DIR}/"
fi

log_subsection "🧾 Validating metadata.name prefix"
PREFIX_ERRORS=0
EXPECTED_PREFIX="${NAME_PREFIX}-"

for f in "${APP_FILES[@]}"; do
  mapfile -t app_names < <(yq eval -r 'select(.kind == "Application") | .metadata.name // ""' "$f" 2>/dev/null || true)
  if [ ${#app_names[@]} -eq 0 ]; then
    continue
  fi

  for name in "${app_names[@]}"; do
    if [ -z "$name" ]; then
      log_error "Missing metadata.name for Application in file: $f"
      PREFIX_ERRORS=$((PREFIX_ERRORS + 1))
      continue
    fi
    if [[ "$name" != "${EXPECTED_PREFIX}"* ]]; then
      log_error "PREFIX_VIOLATION file=$f name=$name expected_prefix=$EXPECTED_PREFIX"
      PREFIX_ERRORS=$((PREFIX_ERRORS + 1))
    fi
  done
done

TOTAL_TESTS=$((TOTAL_TESTS + 1))
if [ "$PREFIX_ERRORS" -gt 0 ]; then
  add_junit_test "$JUNIT_FILE" "sanity-application-prefix" "failed" "Found $PREFIX_ERRORS Application name(s) without prefix ${EXPECTED_PREFIX}"
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  EXIT_CODE=1
else
  add_junit_test "$JUNIT_FILE" "sanity-application-prefix" "passed"
  log_success "All Application names start with: ${EXPECTED_PREFIX}"
fi

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "PREFIX CHECK PASSED"
else
  log_error "PREFIX CHECK FAILED"
fi

exit $EXIT_CODE
