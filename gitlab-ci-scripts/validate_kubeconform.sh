#!/usr/bin/env bash
# validate_kubeconform.sh - Validate rendered manifests with Kubeconform
#
# Validates all rendered YAML manifests against Kubernetes schemas
# using kubeconform in strict mode with local schemas (airgap-compatible)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gitlab-ci-scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

log_section "✅ Validating Manifests with Kubeconform"

check_required_tools kubeconform find

JUNIT_FILE="${OUT_DIR}/validate-junit.xml"
START_TIME=$(date +%s)
TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "validate"

# ============================================================
# Configure Kubeconform schema location (airgap mode)
# ============================================================

: "${KUBECONFORM_SCHEMA_DIR:=/opt/kubeconform/schemas}"
SCHEMA_DIR="${KUBECONFORM_SCHEMA_DIR}/v${KUBERNETES_VERSION}-standalone-strict"

log_info "Schema Directory: $KUBECONFORM_SCHEMA_DIR"
log_info "Expected Schema Path: $SCHEMA_DIR"
log_info "Kubernetes Version: $KUBERNETES_VERSION"

# Verify local schemas exist
if [ ! -d "${SCHEMA_DIR}" ]; then
  log_critical "Local schemas not found at: $SCHEMA_DIR"
  log_info "Available schemas:"
  ls -la "${KUBECONFORM_SCHEMA_DIR}" 2>/dev/null || log_error "Schema directory not accessible"
  exit 1
fi

log_success "Local schemas found"

# Configure schema location for kubeconform
# Uses file:// protocol for local schemas (airgap-compatible)
KUBECONFORM_SCHEMA_LOCATIONS=(
  -schema-location "file://${KUBECONFORM_SCHEMA_DIR}/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json"
)

# ============================================================
# Find all rendered manifests
# ============================================================

if [ ! -d "$RENDERED_DIR" ]; then
  log_critical "Rendered directory not found: $RENDERED_DIR"
  log_critical "Did the render stage complete successfully?"
  exit 1
fi

MANIFEST_FILES=()
while IFS= read -r manifest; do
  [ -z "$manifest" ] && continue
  MANIFEST_FILES+=("$manifest")
done < <(find "${RENDERED_DIR}" -type f -name "*.yaml" -print 2>/dev/null || true) || true

if [ ${#MANIFEST_FILES[@]} -eq 0 ]; then
  log_info "No rendered manifests found in $RENDERED_DIR"
  log_info "Nothing to validate"
  finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
  exit 0
fi

log_info "Found ${#MANIFEST_FILES[@]} manifest file(s) to validate"

# ============================================================
# Validate each manifest
# ============================================================

for manifest in "${MANIFEST_FILES[@]}"; do
  COMPONENT_START=$(date +%s)
  COMPONENT_NAME=$(basename "$manifest" .yaml)
  
  log_subsection "🔍 Validating: $COMPONENT_NAME"
  log_info "File: $manifest"
  
  COMPONENT_STATUS="passed"
  COMPONENT_ERRORS=()
  
  # Check if file is empty
  if [ ! -s "$manifest" ]; then
    log_warning "Manifest is empty (may be valid if chart has no resources)"
    COMPONENT_STATUS="passed"
  else
    # Count resources
    resource_count=$(awk '
      /^---/ {count++}
      /^[[:space:]]*[^#[:space:]]/ {has_content=1}
      END {
        if (!has_content) {
          print 0
        } else if (count == 0) {
          print 1
        } else {
          print count
        }
      }
    ' "$manifest" 2>/dev/null || echo "0")
    log_info "Resources: ~$resource_count"
    
    # Run kubeconform
    VALIDATION_OUTPUT="${OUT_DIR}/${COMPONENT_NAME}.validation.log"
    
    log_info "Running kubeconform..."
    first_doc_line=$(awk '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      {print; exit}
    ' "$manifest")
    manifest_for_validation="$manifest"
    if [ "$first_doc_line" != "---" ]; then
      manifest_for_validation="$(mktemp)"
      printf '%s\n' "---" > "$manifest_for_validation"
      cat "$manifest" >> "$manifest_for_validation"
    fi

    if kubeconform \
      "${KUBECONFORM_SCHEMA_LOCATIONS[@]}" \
      -kubernetes-version "${KUBERNETES_VERSION}" \
      -summary \
      -strict \
      -ignore-missing-schemas \
      "${manifest_for_validation}" > "$VALIDATION_OUTPUT" 2>&1; then
      
      # Validation passed
      log_success "Kubeconform validation passed"
      
      # Show summary
      if grep -q "Summary:" "$VALIDATION_OUTPUT"; then
        grep -A 5 "Summary:" "$VALIDATION_OUTPUT" | while IFS= read -r line; do
          log_info "  $line"
        done
      fi
    else
      # Validation failed
      log_error "Kubeconform validation failed"
      COMPONENT_ERRORS+=("kubeconform validation failed")
      COMPONENT_STATUS="failed"
      EXIT_CODE=1
      
      # Show errors
      log_error "Validation errors:"
      cat "$VALIDATION_OUTPUT" | while IFS= read -r line; do
        log_error "  $line"
      done
    fi

    if [ "$manifest_for_validation" != "$manifest" ]; then
      rm -f "$manifest_for_validation"
    fi
  fi
  
  # Record test result
  COMPONENT_END=$(date +%s)
  COMPONENT_TIME=$((COMPONENT_END - COMPONENT_START))
  
  if [ "$COMPONENT_STATUS" = "passed" ]; then
    log_success "Component $COMPONENT_NAME validated successfully (${COMPONENT_TIME}s)"
    add_junit_test "$JUNIT_FILE" "${COMPONENT_NAME}" "passed" "" "$COMPONENT_TIME"
  else
    ERROR_MSG=$(IFS="; "; echo "${COMPONENT_ERRORS[*]}")
    log_error "Component $COMPONENT_NAME failed validation"
    add_junit_test "$JUNIT_FILE" "${COMPONENT_NAME}" "failed" "${ERROR_MSG}" "$COMPONENT_TIME"
  fi
  
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  if [ "$COMPONENT_STATUS" = "failed" ]; then
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  fi
done

# ============================================================
# Summary
# ============================================================

log_section "Validation Summary"
log_info "Total Manifests: $TOTAL_TESTS"
log_info "Failures: $TOTAL_FAILURES"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "ALL MANIFESTS VALIDATED SUCCESSFULLY"
else
  log_error "VALIDATION FAILED FOR SOME MANIFESTS"
fi

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"

exit $EXIT_CODE
