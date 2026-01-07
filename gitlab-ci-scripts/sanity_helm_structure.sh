#!/usr/bin/env bash
# sanity_helm_structure.sh - Validate Helm Umbrella Chart conventions (Dependencies vs Values)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"

log_section "🛡️ Starting Helm Structure Sanity Checks"

check_required_tools yq find

OUT_DIR="${OUT_DIR:-out}"
JUNIT_FILE="${OUT_DIR}/sanity-helm-junit.xml"
START_TIME=$(date +%s)

TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "sanity-helm"

# Find all Chart.yaml files (identifying Helm Wrapper components)
log_subsection "🔍 Discovering Helm Charts"
mapfile -d "" CHART_FILES < <(find "$COMPONENTS_DIR" -name Chart.yaml -print0 2>/dev/null || true)

if [ ${#CHART_FILES[@]} -eq 0 ]; then
  log_info "No Chart.yaml files found. Skipping Helm structure checks."
  finalize_junit "$JUNIT_FILE" "0" "0" "$START_TIME"
  exit 0
fi

log_info "Found ${#CHART_FILES[@]} chart(s) to validate."

# Check: Dependency Keys in values.yaml
log_subsection "🔑 Check: Validating Dependency Keys in values.yaml"

for chart_file in "${CHART_FILES[@]}"; do
  component_dir="$(dirname "$chart_file")"
  component_name="$(basename "$component_dir")"
  values_file="${component_dir}/values.yaml"
  
  test_name="sanity-helm-deps-${component_name}"
  
  # Check if values.yaml exists
  if [ ! -f "$values_file" ]; then
    msg="values.yaml missing for Helm component: $component_name"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$test_name" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  # Extract dependencies logic:
  # 1. Get array of dependencies
  # 2. Use alias if present, otherwise use name (.alias // .name)
  # 3. Handle null/empty dependencies gracefully
  
  # Note: logic handles cases where dependencies block is missing or null
  mapfile -t EXPECTED_KEYS < <(yq eval '.dependencies[]? | .alias // .name' "$chart_file" 2>/dev/null || true)

  if [ ${#EXPECTED_KEYS[@]} -eq 0 ]; then
    log_info "Component '$component_name': No dependencies defined. Skipping."
    add_junit_test "$JUNIT_FILE" "$test_name" "passed"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    continue
  fi

  missing_keys=()
  for key in "${EXPECTED_KEYS[@]}"; do
    # Check if the key exists at the root of values.yaml
    # Using 'has' returns true/false
    has_key=$(yq eval "has(\"$key\")" "$values_file")
    
    if [ "$has_key" != "true" ]; then
      missing_keys+=("$key")
    fi
  done

  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  if [ ${#missing_keys[@]} -gt 0 ]; then
    log_error "Component '$component_name' failed validation!"
    log_error "  The following keys are defined in Chart.yaml (name or alias) but MISSING in values.yaml:"
    for mk in "${missing_keys[@]}"; do
      log_error "    - $mk"
    done
    
    msg="Missing keys in values.yaml matching Chart.yaml dependencies: ${missing_keys[*]}"
    add_junit_test "$JUNIT_FILE" "$test_name" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
  else
    log_success "Component '$component_name': All dependency keys present."
    add_junit_test "$JUNIT_FILE" "$test_name" "passed"
  fi
done

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "HELM STRUCTURE CHECKS PASSED"
else
  log_error "HELM STRUCTURE CHECKS FAILED"
fi

exit $EXIT_CODE