#!/usr/bin/env bash
# render_helm.sh - Render Helm charts and prepare raw manifests
#
# For each target component:
# 1) Detects if it's a Helm wrapper (Chart.yaml present) or raw manifests
# 2) Helm: dependency build + lint + template -> rendered/<component>.yaml
# 3) Raw: validates YAML and concatenates files as MULTI-DOCUMENT YAML (with --- separators)
# 4) Outputs to rendered/ and writes JUnit report to out/render-junit.xml
#
# Inputs:
# - Target components list: out/target_components.txt  (one component name per line)
# - Components dir: ${GITOPS_COMPONENTS_DIR:-components}
#
# Output:
# - rendered/<component>.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------
# Config
# -----------------------------
COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"
OUT_DIR="${OUT_DIR:-out}"
RENDERED_DIR="${RENDERED_DIR:-rendered}"

TARGET_COMPONENTS_FILE="${OUT_DIR}/target_components.txt"

HELM_INCLUDE_CRDS="${HELM_INCLUDE_CRDS:-false}"
HELM_TIMEOUT="${HELM_TIMEOUT:-300}" # seconds (mostly for helm dependency/network ops)

mkdir -p "${OUT_DIR}" "${RENDERED_DIR}"

log_section "🎨 Rendering Components"

# -----------------------------
# Tool checks
# -----------------------------
check_required_tools yq find sort awk helm

# -----------------------------
# JUnit init
# -----------------------------
JUNIT_FILE="${OUT_DIR}/render-junit.xml"
START_TIME=$(date +%s)

TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "render"

# -----------------------------
# Read targets
# -----------------------------
if [ ! -f "${TARGET_COMPONENTS_FILE}" ]; then
  log_critical "Target components file not found: ${TARGET_COMPONENTS_FILE}"
  log_critical "Expected it to be created by git_changed_components.sh"
  add_junit_test "$JUNIT_FILE" "render-target-components-file" "failed" "Missing ${TARGET_COMPONENTS_FILE}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
  exit 1
fi

mapfile -t TARGET_COMPONENTS < "${TARGET_COMPONENTS_FILE}"

if [ ${#TARGET_COMPONENTS[@]} -eq 0 ]; then
  log_info "No components to render (empty target list)."
  add_junit_test "$JUNIT_FILE" "render-empty-target-list" "passed" "No components to render"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
  exit 0
fi

log_info "Rendering ${#TARGET_COMPONENTS[@]} component(s) from ${COMPONENTS_DIR}/ into ${RENDERED_DIR}/"

# -----------------------------
# Helpers
# -----------------------------
get_yq() {
  local file="$1"
  local expr="$2"
  yq eval -r "${expr} // \"\"" "$file" 2>/dev/null || true
}

resolve_source_dir() {
  local app_dir="$1"
  local source_path="$2"

  if [ -z "$source_path" ] || [ "$source_path" = "." ]; then
    echo "$app_dir"
    return 0
  fi

  # Security: block absolute paths or path traversal
  if [[ "$source_path" == /* ]] || [[ "$source_path" == *".."* ]]; then
    return 1
  fi

  if [ "$source_path" = "manifests" ] || [ "$source_path" = "./manifests" ]; then
    echo "${app_dir}/manifests"
    return 0
  fi

  if [[ "$source_path" == ./* ]]; then
    echo "${app_dir}/${source_path#./}"
    return 0
  fi

  # default: treat as relative to app_dir
  echo "${app_dir}/${source_path}"
  return 0
}

append_yaml_multi_doc() {
  # Appends yaml_file to output_file as proper multi-document YAML.
  # - Adds "---" between files if needed
  # - Adds "# Source: ..." comment for debug
  # - If yaml_file contains multiple resources but lacks '---', inject separators before subsequent apiVersion blocks.
  local output_file="$1"
  local yaml_file="$2"
  local first_flag="$3" # "true" or "false"

  # If this isn't the first document, ensure separator exists
  if [ "$first_flag" = "false" ]; then
    # If the file already starts with '---', don't add another one
    if ! head -n 1 "$yaml_file" | grep -qE '^[[:space:]]*---[[:space:]]*$'; then
      echo "---" >> "$output_file"
    fi
  fi

  echo "# Source: ${yaml_file}" >> "$output_file"

  # If file already has separators, just append as-is
  if grep -qE '^[[:space:]]*---[[:space:]]*$' "$yaml_file"; then
    cat "$yaml_file" >> "$output_file"
    echo "" >> "$output_file"
    return 0
  fi

  # Otherwise, if it contains multiple apiVersion blocks, inject separators before subsequent ones
  local api_count
  api_count=$(grep -cE '^[[:space:]]*apiVersion:[[:space:]]*' "$yaml_file" 2>/dev/null || true)

  if [ "${api_count}" -gt 1 ]; then
    log_warning "Multi-resource raw file without '---' detected; auto-fixing: $yaml_file"
    awk -v src="$yaml_file" '
      BEGIN { seen=0 }
      /^[[:space:]]*apiVersion:[[:space:]]*/ {
        if (seen==1) {
          print "---"
          print "# Source: " src " (continued)"
        }
        seen=1
      }
      { print }
    ' "$yaml_file" >> "$output_file"
  else
    cat "$yaml_file" >> "$output_file"
  fi

  echo "" >> "$output_file"
}

# -----------------------------
# Render loop
# -----------------------------
for COMP in "${TARGET_COMPONENTS[@]}"; do
  COMP="$(echo "$COMP" | xargs)"
  [ -z "$COMP" ] && continue

  TEST_NAME="render-${COMP}"
  T0=$(date +%s)
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  APP_DIR="${COMPONENTS_DIR}/${COMP}"
  APP_FILE="${APP_DIR}/application.yml"
  OUTPUT_FILE="${RENDERED_DIR}/${COMP}.yaml"

  log_subsection "📦 Component: ${COMP}"

  if [ ! -d "$APP_DIR" ]; then
    msg="Component directory not found: ${APP_DIR}"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  if [ ! -f "$APP_FILE" ]; then
    msg="application.yml not found: ${APP_FILE}"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  APP_NAME="$(get_yq "$APP_FILE" ".metadata.name")"
  NAMESPACE="$(get_yq "$APP_FILE" ".spec.destination.namespace")"
  SOURCE_PATH="$(get_yq "$APP_FILE" ".spec.source.path")"

  [ -z "$APP_NAME" ] && APP_NAME="$COMP"
  [ -z "$NAMESPACE" ] && NAMESPACE="default"

  if ! SOURCE_DIR="$(resolve_source_dir "$APP_DIR" "$SOURCE_PATH")"; then
    msg="Invalid spec.source.path (unsafe): '${SOURCE_PATH}' in ${APP_FILE}"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  log_info "Application: ${APP_NAME}"
  log_info "Namespace:   ${NAMESPACE}"
  log_info "SourcePath:  ${SOURCE_PATH:-.}"
  log_info "SourceDir:   ${SOURCE_DIR}"

  if [ ! -d "$SOURCE_DIR" ]; then
    msg="Resolved source directory not found: ${SOURCE_DIR}"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  # Clean output
  : > "$OUTPUT_FILE"

  # -----------------------------
  # Helm wrapper
  # -----------------------------
  if [ -f "${SOURCE_DIR}/Chart.yaml" ]; then
    log_info "Detected Helm Wrapper (Chart.yaml present)"

    (
      cd "$SOURCE_DIR"

      # Helm dependency build/lint/template
      # Note: helm template itself doesn't use timeout, but dependency build may.
      helm dependency build >/dev/null
      helm lint . >/dev/null

      HELM_ARGS=()
      if [ "$HELM_INCLUDE_CRDS" = "true" ]; then
        HELM_ARGS+=(--include-crds)
      fi

      helm template "${APP_NAME}" . \
        --namespace "${NAMESPACE}" \
        "${HELM_ARGS[@]}" \
        > "${CI_PROJECT_DIR}/${OUTPUT_FILE}"
    )

  # -----------------------------
  # Raw manifests
  # -----------------------------
  else
    log_info "Detected Raw Manifests"

    mapfile -d "" RAW_FILES < <(
      find "$SOURCE_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null | sort -z || true
    )

    if [ ${#RAW_FILES[@]} -eq 0 ]; then
      msg="No YAML manifests found under: ${SOURCE_DIR}"
      log_error "$msg"
      add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
      TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
      EXIT_CODE=1
      continue
    fi

    first_doc=true
    YAML_ERRORS=0

    for yaml_file in "${RAW_FILES[@]}"; do
      # Validate YAML parse
      if ! yq eval '.' "$yaml_file" >/dev/null 2>&1; then
        log_error "Invalid YAML: $yaml_file"
        YAML_ERRORS=$((YAML_ERRORS + 1))
        continue
      fi

      # Append as multi-doc YAML with proper separators
      if [ "$first_doc" = true ]; then
        append_yaml_multi_doc "$OUTPUT_FILE" "$yaml_file" "true"
        first_doc=false
      else
        append_yaml_multi_doc "$OUTPUT_FILE" "$yaml_file" "false"
      fi
    done

    if [ "$YAML_ERRORS" -gt 0 ]; then
      msg="Found ${YAML_ERRORS} invalid YAML file(s) under: ${SOURCE_DIR}"
      log_error "$msg"
      add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
      TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
      EXIT_CODE=1
      continue
    fi
  fi

  # Basic output sanity
  if [ ! -s "$OUTPUT_FILE" ]; then
    msg="Rendered output is empty: ${OUTPUT_FILE}"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  T1=$(date +%s)
  DT=$((T1 - T0))
  add_junit_test "$JUNIT_FILE" "$TEST_NAME" "passed" "" "$DT"
  log_success "Rendered -> ${OUTPUT_FILE} (${DT}s)"
done

# -----------------------------
# Summary + finalize
# -----------------------------
log_section "Rendering Summary"
log_info "Total Components: $TOTAL_TESTS"
log_info "Failures: $TOTAL_FAILURES"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "ALL COMPONENTS RENDERED SUCCESSFULLY"
else
  log_error "RENDERING FAILED FOR SOME COMPONENTS"
fi

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
exit $EXIT_CODE