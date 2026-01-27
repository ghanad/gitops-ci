#!/usr/bin/env bash
# validate_hardcoded_namespace.sh - Enforce no hardcoded namespaces in rendered manifests
#
# Rules:
# - For any namespaced resource, metadata.namespace must be absent/empty.
# - Cluster-scoped resources are ignored.
# - Namespace, ArgoCD Application, and AppProject are exempt.
# - Supports multi-doc YAML and kind: List with items.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gitlab-ci-scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

log_section "🚫 Validating hardcoded namespaces"

check_required_tools yq find

OUT_DIR="${OUT_DIR:-out}"
RENDERED_DIR="${RENDERED_DIR:-rendered}"
ANNOTATION_KEY="${HARDCODED_NAMESPACE_ANNOTATION:-gitops.mahsan.net/allow-hardcoded-namespace}"
CLUSTER_SCOPED_KINDS_FILE="${CLUSTER_SCOPED_KINDS_FILE:-${SCRIPT_DIR}/cluster_scoped_kinds.txt}"

JUNIT_FILE="${OUT_DIR}/namespace-junit.xml"
START_TIME=$(date +%s)
TOTAL_TESTS=0
TOTAL_FAILURES=0
EXIT_CODE=0

mkdir -p "$OUT_DIR"
init_junit "$JUNIT_FILE" "namespace"

if [ ! -f "$CLUSTER_SCOPED_KINDS_FILE" ]; then
  log_critical "Cluster-scoped kinds list not found: $CLUSTER_SCOPED_KINDS_FILE"
  exit 1
fi

# Load cluster-scoped kinds into a lookup map
declare -A CLUSTER_SCOPED_KINDS
while IFS= read -r kind; do
  kind="$(echo "$kind" | xargs)"
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  CLUSTER_SCOPED_KINDS["$kind"]=1
done < "$CLUSTER_SCOPED_KINDS_FILE"

is_cluster_scoped() {
  local kind="$1"
  [[ -n "${CLUSTER_SCOPED_KINDS[$kind]:-}" ]]
}

is_exempt_kind() {
  local kind="$1"
  case "$kind" in
    Namespace|Application|AppProject)
      return 0
      ;;
  esac
  return 1
}

TARGET_PATH="${1:-$RENDERED_DIR}"

if [ -f "$TARGET_PATH" ]; then
  MANIFEST_FILES=("$TARGET_PATH")
elif [ -d "$TARGET_PATH" ]; then
  mapfile -d "" MANIFEST_FILES < <(find "$TARGET_PATH" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null | sort -z)
else
  log_critical "Rendered path not found: $TARGET_PATH"
  exit 1
fi

if [ ${#MANIFEST_FILES[@]} -eq 0 ]; then
  log_info "No rendered manifests found in $TARGET_PATH"
  log_info "Nothing to validate"
  finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"
  exit 0
fi

log_info "Found ${#MANIFEST_FILES[@]} manifest file(s) to validate"

for manifest in "${MANIFEST_FILES[@]}"; do
  COMPONENT_START=$(date +%s)
  COMPONENT_NAME="$(basename "$manifest")"
  COMPONENT_NAME="${COMPONENT_NAME%.*}"

  log_subsection "🔍 Checking: $COMPONENT_NAME"
  log_info "File: $manifest"

  COMPONENT_STATUS="passed"
  COMPONENT_ERRORS=()
  VIOLATIONS=()

  if [ ! -s "$manifest" ]; then
    log_warning "Manifest is empty (may be valid if chart has no resources)"
  else
    while IFS=$'\t' read -r doc_index item_index api_version kind name namespace allow_namespace; do
      [ -z "$kind" ] && continue

      if is_exempt_kind "$kind"; then
        continue
      fi

      if is_cluster_scoped "$kind"; then
        continue
      fi

      if [ -n "$allow_namespace" ] && [ "${allow_namespace,,}" = "true" ]; then
        continue
      fi

      if [ -n "$namespace" ]; then
        local_doc=$((doc_index + 1))
        local_item=""
        if [ "$item_index" -ge 0 ]; then
          local_item=$((item_index + 1))
        fi

        location="doc=${local_doc}"
        if [ -n "$local_item" ]; then
          location+=" item=${local_item}"
        fi

        msg="component=${COMPONENT_NAME} apiVersion=${api_version:-unknown} kind=${kind} name=${name:-unknown} namespace=${namespace} file=${manifest} ${location}"
        VIOLATIONS+=("$msg")
      fi
    done < <(
      ANNOTATION_KEY="$ANNOTATION_KEY" yq eval-all -N -r '
        (. | select(.kind == "List") | .items | to_entries[]
          | select(.value.kind != null and .value.kind != "")
          | [documentIndex, .key, (.value.apiVersion // ""), (.value.kind // ""), (.value.metadata.name // ""), (.value.metadata.namespace // ""), (.value.metadata.annotations[env(ANNOTATION_KEY)] // "")] | @tsv
        ),
        (. | select(.kind != "List" and .kind != null and .kind != "")
          | [documentIndex, -1, (.apiVersion // ""), (.kind // ""), (.metadata.name // ""), (.metadata.namespace // ""), (.metadata.annotations[env(ANNOTATION_KEY)] // "")] | @tsv
        )
      ' "$manifest"
    )

    if [ ${#VIOLATIONS[@]} -gt 0 ]; then
      COMPONENT_STATUS="failed"
      EXIT_CODE=1
      log_error "Hardcoded namespaces detected in $manifest"
      for v in "${VIOLATIONS[@]}"; do
        log_error "  $v"
      done
      COMPONENT_ERRORS+=("Found ${#VIOLATIONS[@]} hardcoded namespace(s)")
    else
      log_success "No hardcoded namespaces found"
    fi
  fi

  COMPONENT_END=$(date +%s)
  COMPONENT_TIME=$((COMPONENT_END - COMPONENT_START))

  if [ "$COMPONENT_STATUS" = "passed" ]; then
    add_junit_test "$JUNIT_FILE" "$COMPONENT_NAME" "passed" "" "$COMPONENT_TIME"
  else
    ERROR_MSG=$(IFS="; "; echo "${COMPONENT_ERRORS[*]}")
    add_junit_test "$JUNIT_FILE" "$COMPONENT_NAME" "failed" "$ERROR_MSG" "$COMPONENT_TIME"
  fi

  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  if [ "$COMPONENT_STATUS" = "failed" ]; then
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  fi
done

log_section "Namespace Validation Summary"
log_info "Total Manifests: $TOTAL_TESTS"
log_info "Failures: $TOTAL_FAILURES"

if [ $EXIT_CODE -eq 0 ]; then
  log_success "NO HARDCODED NAMESPACES DETECTED"
else
  log_error "HARDCODED NAMESPACES DETECTED"
fi

finalize_junit "$JUNIT_FILE" "$TOTAL_TESTS" "$TOTAL_FAILURES" "$START_TIME"

exit $EXIT_CODE
