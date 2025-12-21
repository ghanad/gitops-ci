#!/usr/bin/env bash
# render_helm.sh - Render Helm charts and prepare raw manifests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"

log_section "🎨 Rendering Components"

check_required_tools helm yq find

OUT_DIR="${OUT_DIR:-out}"
RENDERED_DIR="${RENDERED_DIR:-rendered}"

JUNIT_FILE="${OUT_DIR}/render-junit.xml"
START_TIME=$(date +%s)
TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

init_junit "$JUNIT_FILE" "render"

if [ ! -f "${OUT_DIR}/target_components.txt" ]; then
  log_critical "Target components file not found: ${OUT_DIR}/target_components.txt"
  log_critical "Did git_changed_components.sh run successfully?"
  exit 1
fi

mapfile -t TARGET_COMPONENTS < "${OUT_DIR}/target_components.txt"

if [ ${#TARGET_COMPONENTS[@]} -eq 0 ]; then
  log_info "No components to render"
  finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
  exit 0
fi

log_info "Rendering ${#TARGET_COMPONENTS[@]} component(s) into ${RENDERED_DIR}/"

mkdir -p "$RENDERED_DIR"

for APP in "${TARGET_COMPONENTS[@]}"; do
  TEST_NAME="render-${APP}"
  T0=$(date +%s)

  APP_PATH="${COMPONENTS_DIR}/${APP}"
  APP_FILE="${APP_PATH}/application.yml"

  if [ ! -f "$APP_FILE" ]; then
    msg="application.yml not found for component: $APP"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  fi

  APP_NAME="$(get_app_metadata "$APP_FILE" "metadata.name")"
  TARGET_NS="$(get_app_metadata "$APP_FILE" "spec.destination.namespace")"
  SOURCE_PATH="$(get_app_metadata "$APP_FILE" "spec.source.path")"

  SOURCE_DIR="$(normalize_source_dir "$APP_PATH" "$SOURCE_PATH")" || {
    msg="Invalid spec.source.path: $SOURCE_PATH"
    log_error "$msg"
    add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    EXIT_CODE=1
    continue
  }

  OUTPUT_FILE="${RENDERED_DIR}/${APP}.yaml"

  log_subsection "📦 Component: $APP"
  log_info "Application: ${APP_NAME:-$APP}"
  log_info "Namespace: ${TARGET_NS:-<unset>}"
  log_info "Source Path: ${SOURCE_PATH:-.}"
  log_info "Resolved Source Dir: $SOURCE_DIR"

  if [ -f "${SOURCE_DIR}/Chart.yaml" ]; then
    log_info "Detected Helm Wrapper (Chart.yaml present)"
    (
      cd "$SOURCE_DIR"
      helm dependency build
      helm lint .
      helm template "${APP_NAME:-$APP}" . \
        --namespace "${TARGET_NS:-default}" \
        $( [ "${HELM_INCLUDE_CRDS:-false}" = "true" ] && echo "--include-crds" ) \
        --timeout "${HELM_TIMEOUT:-300}s" \
        > "${CI_PROJECT_DIR}/${OUTPUT_FILE}"
    )
  else
    log_info "Detected Raw Manifests"
    if [ ! -d "$SOURCE_DIR" ]; then
      msg="Source directory not found: $SOURCE_DIR"
      log_error "$msg"
      add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
      TOTAL_TESTS=$((TOTAL_TESTS + 1))
      TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
      EXIT_CODE=1
      continue
    fi

    mapfile -d "" RAW_FILES < <(find "$SOURCE_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 | sort -z)
    if [ ${#RAW_FILES[@]} -eq 0 ]; then
      msg="No YAML manifests found under: $SOURCE_DIR"
      log_error "$msg"
      add_junit_test "$JUNIT_FILE" "$TEST_NAME" "failed" "$msg"
      TOTAL_TESTS=$((TOTAL_TESTS + 1))
      TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
      EXIT_CODE=1
      continue
    fi

    : > "$OUTPUT_FILE"
    for f in "${RAW_FILES[@]}"; do
      yq eval '.' "$f" >/dev/null
      cat "$f" >> "$OUTPUT_FILE"
      echo >> "$OUTPUT_FILE"
    done
  fi

  T1=$(date +%s)
  DT=$((T1 - T0))
  add_junit_test "$JUNIT_FILE" "$TEST_NAME" "passed" "" "$DT"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
done

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
exit $EXIT_CODE
