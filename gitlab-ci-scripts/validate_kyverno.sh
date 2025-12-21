#!/usr/bin/env bash
# validate_kyverno.sh - Validate rendered manifests with Kyverno policies (CI-only)
#
# Policy resolution:
# - Baseline policies live next to these scripts in the gitops-ci repo:  <gitops-ci>/policies/kyverno/<set>/*.yml
# - Optional repo-local policies may live in the target repo:            <repo>/policies/kyverno/<set>/*.yml
#
# Enable sets via:
#   KYVERNO_POLICYSETS="baseline"            (default)
#   KYVERNO_POLICYSETS="baseline,security"  (example)
#   KYVERNO_POLICYSETS="baseline,tenant"    (tenant repo adds policies/kyverno/tenant)
#
# Notes:
# - We intentionally *fail* the pipeline on Kyverno warnings too (via --warn-exit-code),
#   because CI is a gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

log_section "🛡️  Validating with Kyverno Policies"

check_required_tools kyverno find yq

OUT_DIR="${OUT_DIR:-out}"
RENDERED_DIR="${RENDERED_DIR:-rendered}"

CI_LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_POLICIES_ROOT="${CI_LIB_ROOT}/policies/kyverno"

LOCAL_POLICIES_ROOT="${LOCAL_POLICIES_ROOT:-policies/kyverno}"

KYVERNO_POLICYSETS="${KYVERNO_POLICYSETS:-baseline}"
KYVERNO_STRICT_SETS="${KYVERNO_STRICT_SETS:-true}"

mkdir -p "$OUT_DIR"

KYVERNO_OUTPUT="${OUT_DIR}/kyverno-output.txt"
KYVERNO_REPORT="${OUT_DIR}/kyverno-policy-report.txt"
COMBINED_MANIFESTS="${OUT_DIR}/combined-rendered.yaml"
POLICY_TMP_DIR="${OUT_DIR}/kyverno-policies"

if [ ! -d "$RENDERED_DIR" ]; then
  log_info "Rendered directory not found: $RENDERED_DIR"
  log_info "Nothing to validate with Kyverno"
  exit 0
fi

mapfile -d "" MANIFEST_FILES < <(
  find "${RENDERED_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null | sort -z || true
)

if [ ${#MANIFEST_FILES[@]} -eq 0 ]; then
  log_info "No rendered manifests found in $RENDERED_DIR"
  log_info "Nothing to validate with Kyverno"
  exit 0
fi

: > "$COMBINED_MANIFESTS"
for f in "${MANIFEST_FILES[@]}"; do
  [ ! -s "$f" ] && continue
  cat "$f" >> "$COMBINED_MANIFESTS"
  echo >> "$COMBINED_MANIFESTS"
done

if [ ! -s "$COMBINED_MANIFESTS" ]; then
  log_info "Combined manifest file is empty. Nothing to validate."
  exit 0
fi

rm -rf "$POLICY_TMP_DIR"
mkdir -p "$POLICY_TMP_DIR"

IFS=',' read -r -a SETS <<< "$KYVERNO_POLICYSETS"

log_info "Requested Kyverno policy sets: $KYVERNO_POLICYSETS"
log_info "Baseline policy root: $BASELINE_POLICIES_ROOT"
log_info "Local policy root:    $LOCAL_POLICIES_ROOT"

TOTAL_POLICIES=0
MISSING_SETS=()

copy_policies_from_dir() {
  local src_dir="$1"
  local set_name="$2"

  [ ! -d "$src_dir" ] && return 1

  local found=false
  shopt -s nullglob
  for p in "$src_dir"/*.yml "$src_dir"/*.yaml; do
    found=true
    local base
    base="$(basename "$p")"
    cp "$p" "${POLICY_TMP_DIR}/${set_name}__${base}"
    TOTAL_POLICIES=$((TOTAL_POLICIES + 1))
  done
  shopt -u nullglob

  $found && return 0 || return 1
}

for set in "${SETS[@]}"; do
  set="$(echo "$set" | xargs)"
  [ -z "$set" ] && continue

  found_any=false

  if copy_policies_from_dir "${BASELINE_POLICIES_ROOT}/${set}" "${set}-baseline"; then
    found_any=true
  fi

  if copy_policies_from_dir "${LOCAL_POLICIES_ROOT}/${set}" "${set}-local"; then
    found_any=true
  fi

  if [ "$found_any" = false ]; then
    MISSING_SETS+=("$set")
  fi
done

if [ ${#MISSING_SETS[@]} -gt 0 ] && [ "$KYVERNO_STRICT_SETS" = "true" ]; then
  log_error "Requested policy set(s) not found in baseline OR local roots:"
  for s in "${MISSING_SETS[@]}"; do
    log_error "  - $s"
  done
  exit 1
fi

if [ $TOTAL_POLICIES -eq 0 ]; then
  log_info "No Kyverno policies found for requested sets. Skipping."
  exit 0
fi

log_info "Collected $TOTAL_POLICIES policy file(s) into $POLICY_TMP_DIR"

log_info "Running Kyverno policy validation..."
log_info "Command: kyverno apply $POLICY_TMP_DIR --resource $COMBINED_MANIFESTS --audit-warn --warn-exit-code 1 --policy-report"

if kyverno apply "$POLICY_TMP_DIR" \
  --resource "$COMBINED_MANIFESTS" \
  --audit-warn \
  --warn-exit-code 1 \
  --policy-report > "$KYVERNO_OUTPUT" 2>&1; then

  log_success "All Kyverno policy checks passed!"
else
  log_error "Kyverno policy violations detected."
  cp "$KYVERNO_OUTPUT" "$KYVERNO_REPORT"
  exit 1
fi

cp "$KYVERNO_OUTPUT" "$KYVERNO_REPORT"
log_success "ALL KYVERNO POLICIES PASSED"
exit 0
