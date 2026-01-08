#!/usr/bin/env bash
# lib.sh - Common functions and helpers for GitOps validation pipeline

set -euo pipefail

# Repo layout defaults (override via CI variables)
COMPONENTS_DIR="${GITOPS_COMPONENTS_DIR:-components}"

# ============================================================
# Logging helpers
# All log functions write to stderr to keep stdout clean for data
# ============================================================

log_info() { echo "ℹ️  $*" >&2; }
log_success() { echo "✅ $*" >&2; }
log_warning() { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }
log_critical() { echo "🛑 $*" >&2; }

log_section() {
  echo "" >&2
  echo "============================================================" >&2
  echo "$*" >&2
  echo "============================================================" >&2
}

log_subsection() {
  echo "" >&2
  echo "-----------------------------" >&2
  echo "$*" >&2
  echo "-----------------------------" >&2
}

# ============================================================
# Tool checks
# ============================================================

check_required_tools() {
  local missing=()
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_critical "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

# ============================================================
# XML / JUnit helpers
# ============================================================

xml_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  s="${s//\'/\&apos;}"
  printf "%s" "$s"
}

init_junit() {
  local junit_file="$1"
  local suite_name="$2"
  mkdir -p "$(dirname "$junit_file")"
  cat > "$junit_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="$(xml_escape "$suite_name")">
EOF
}

add_junit_test() {
  local junit_file="$1"
  local name="$2"
  local status="$3"     # passed|failed
  local message="${4:-}"
  local time="${5:-0}"

  local escaped_name
  escaped_name="$(xml_escape "$name")"

  # truncate message to avoid huge junit
  if [ ${#message} -gt 500 ]; then
    message="${message:0:497}..."
  fi

  cat >> "$junit_file" <<EOF
  <testcase name="$escaped_name" classname="validation" time="$time">
EOF

  if [ "$status" = "failed" ]; then
    local escaped_msg
    escaped_msg="$(xml_escape "$message")"
    cat >> "$junit_file" <<EOF
    <failure message="Validation failed">$escaped_msg</failure>
EOF
  fi

  cat >> "$junit_file" <<EOF
  </testcase>
EOF
}

finalize_junit() {
  local junit_file="$1"
  local total_tests="$2"
  local total_failures="$3"
  local start_time="$4"
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Inject totals into the opening testsuite tag
  # (simple and robust: rewrite first line with attributes)
  local tmp="${junit_file}.tmp"
  {
    read -r line1
    read -r line2
    echo "$line1"
    echo "<testsuite name=\"validation\" tests=\"$total_tests\" failures=\"$total_failures\" time=\"$duration\">"
    cat
  } < "$junit_file" > "$tmp" || true

  mv "$tmp" "$junit_file"

  echo "</testsuite>" >> "$junit_file"
}

# ============================================================
# Component helpers
# ============================================================

get_all_components() {
  find "$COMPONENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | cut -d/ -f2 | sort || true
}

# ============================================================
# Application metadata extraction
# ============================================================

get_app_metadata() {
  local app_file="$1"
  local field="$2"
  yq eval -r ".${field} // \"\"" "$app_file" 2>/dev/null || true
}

normalize_source_dir() {
  local app_dir="$1"
  local source_path="$2"

  if [ -z "$source_path" ] || [ "$source_path" = "." ]; then
    echo "$app_dir"
    return 0
  fi

  if [[ "$source_path" == /* ]] || [[ "$source_path" == *".."* ]]; then
    log_error "Unsafe source path: $source_path"
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

  echo "$source_path"
  return 0
}
