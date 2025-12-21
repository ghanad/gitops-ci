#!/usr/bin/env bash
# git_changed_components.sh - Intelligent component change detection with 3-mode decision

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

OUT_DIR="${OUT_DIR:-out}"
mkdir -p "$OUT_DIR"

FORCE_FULL="${FORCE_FULL_SCAN:-false}"
COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"

# Full scan triggers
FULL_SCAN_PATTERNS=(
  '.gitlab-ci.yml'
  'gitlab-ci.yml'
  '.gitlab-ci.yaml'
  'gitlab-ci-scripts/**'
  'scripts/**'
  'templates/**'
  'schemas/**'
  'policies/**'
  'shared/**'
  'common/**'
  'base/**'
  'kustomization.yaml'
  'kustomization.yml'
)

# Skip-only changes
SKIP_PATTERNS=(
  'README.md'
  'docs/**'
  '*.md'
  '.gitignore'
  '.editorconfig'
)

matches_pattern() {
  local file="$1"; shift
  local patterns=("$@")
  for p in "${patterns[@]}"; do
    if [[ "$file" == $p ]]; then
      return 0
    fi
  done
  return 1
}

log_section "🧠 Detecting Changed Components"

MODE=""
SKIP_SCAN=false
PARTIAL_SCAN=false
FULL_SCAN=false
CHANGED_COMPONENTS=()

# Compute diff range
BASE_SHA="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-${CI_COMMIT_BEFORE_SHA:-}}"
HEAD_SHA="${CI_COMMIT_SHA:-}"

DIFF_FAILED=false
DIFF_FAILURE_REASON=""

if [ "$FORCE_FULL" = "true" ]; then
  log_warning "FORCE_FULL_SCAN=true detected"
  MODE="FULL"
  DIFF_FAILURE_REASON="Forced via FORCE_FULL_SCAN variable"
fi

if [ -z "$BASE_SHA" ] || [ "$BASE_SHA" = "0000000000000000000000000000000000000000" ]; then
  log_warning "Base SHA is missing/invalid; falling back to FULL scan"
  MODE="FULL"
  DIFF_FAILURE_REASON="Missing/invalid base SHA"
fi

CHANGED_FILES_ARRAY=()
if [ -z "$MODE" ]; then
  log_info "Diff range: $BASE_SHA..$HEAD_SHA"

  if ! mapfile -t CHANGED_FILES_ARRAY < <(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null); then
    DIFF_FAILED=true
    DIFF_FAILURE_REASON="git diff failed"
    MODE="FULL"
  fi

  if [ ${#CHANGED_FILES_ARRAY[@]} -eq 0 ]; then
    log_info "No changed files detected (empty diff)."
    MODE="SKIP"
  fi
fi

# Classification
if [ -z "$MODE" ]; then
  has_full_scan=false
  has_component_changes=false
  has_other_changes=false
  has_skip_only=true

  full_scan_count=0
  component_count=0
  other_count=0
  skip_count=0

  log_info "Changed files:"
  for file in "${CHANGED_FILES_ARRAY[@]}"; do
    if matches_pattern "$file" "${FULL_SCAN_PATTERNS[@]}"; then
      has_full_scan=true
      has_skip_only=false
      full_scan_count=$((full_scan_count + 1))
      log_info "  [FULL] $file"
    elif matches_pattern "$file" "${SKIP_PATTERNS[@]}"; then
      skip_count=$((skip_count + 1))
      log_info "  [SKIP] $file"
    elif [[ "$file" == "${COMPONENTS_DIR}/"* ]]; then
      has_component_changes=true
      has_skip_only=false
      component_count=$((component_count + 1))
      log_info "  [COMP] $file"
    else
      has_other_changes=true
      has_skip_only=false
      other_count=$((other_count + 1))
      log_info "  [OTHER] $file"
    fi
  done

  log_info ""
  log_info "Classification Summary:"
  log_info "  Full-scan triggers: $full_scan_count"
  log_info "  Component changes: $component_count"
  log_info "  Other changes: $other_count"
  log_info "  Skip-eligible: $skip_count"

  if [ "$has_full_scan" = true ]; then
    MODE="FULL"
  elif [ "$has_skip_only" = true ]; then
    MODE="SKIP"
  elif [ "$has_component_changes" = true ] && [ "$has_other_changes" = false ]; then
    MODE="PARTIAL"
  else
    MODE="FULL"
  fi
fi

case "$MODE" in
  SKIP)
    SKIP_SCAN=true
    ;;
  PARTIAL)
    PARTIAL_SCAN=true
    log_info "Extracting changed component names from ${COMPONENTS_DIR}/ ..."

    mapfile -t CHANGED_COMPONENTS < <(
      printf "%s\n" "${CHANGED_FILES_ARRAY[@]}" | \
      grep "^${COMPONENTS_DIR}/" | \
      sed "s#^${COMPONENTS_DIR}/##" | \
      cut -d/ -f1 | \
      sort -u || true
    )

    if [ ${#CHANGED_COMPONENTS[@]} -eq 0 ]; then
      log_error "INTERNAL ERROR: PARTIAL mode but no components found!"
      log_error "Falling back to FULL for safety"
      PARTIAL_SCAN=false
      FULL_SCAN=true
      MODE="FULL"
    fi
    ;;
  FULL)
    FULL_SCAN=true
    if [ ! -d "$COMPONENTS_DIR" ]; then
      log_error "No components found in ${COMPONENTS_DIR}/ directory!"
      CHANGED_COMPONENTS=()
    else
      mapfile -t CHANGED_COMPONENTS < <(get_all_components)
    fi
    ;;
  *)
    log_critical "Unknown mode: $MODE"
    exit 1
    ;;
esac

export SKIP_SCAN PARTIAL_SCAN FULL_SCAN
export SCAN_MODE="$MODE"
export CHANGED_COMPONENTS_COUNT="${#CHANGED_COMPONENTS[@]}"

DOTENV_FILE="${OUT_DIR}/scan-mode.env"
cat > "$DOTENV_FILE" <<EOF
SKIP_SCAN=${SKIP_SCAN}
PARTIAL_SCAN=${PARTIAL_SCAN}
FULL_SCAN=${FULL_SCAN}
SCAN_MODE=${MODE}
CHANGED_COMPONENTS_COUNT=${#CHANGED_COMPONENTS[@]}
EOF

if [ "$SKIP_SCAN" = true ]; then
  log_success "✓ Scan can be skipped - no components to output"
  exit 0
fi

log_info "Target components:"
for component in "${CHANGED_COMPONENTS[@]}"; do
  log_info "  → $component"
  echo "$component"
done

log_success "✓ Change detection complete ($MODE mode, ${#CHANGED_COMPONENTS[@]} components)"
