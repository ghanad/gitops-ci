#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/git_changed_components.sh"
}

setup() {
  load_lib
  
  # Create temp directory
  TEST_DIR=$(mktemp -d)
  
  # Save original directory to return later
  ORIGINAL_PWD="$PWD"
  
  # Switch to temp dir to simulate root of the repo
  cd "$TEST_DIR"
  
  # Use RELATIVE paths (Crucial for the script logic to work)
  export GITOPS_COMPONENTS_DIR="components"
  export OUT_DIR="out"
  
  mkdir -p "$GITOPS_COMPONENTS_DIR" "$OUT_DIR"
  
  # Dummy defaults
  export CI_MERGE_REQUEST_DIFF_BASE_SHA="sha-base"
  export CI_COMMIT_SHA="sha-head"
  export FORCE_FULL_SCAN="false"

  # --- MOCKING ---
  
  function check_required_tools() {
    return 0
  }
  export -f check_required_tools

  function git() {
    if [[ "$1" == "diff" ]]; then
      echo "$MOCK_GIT_DIFF"
      return 0
    fi
    return 0
  }
  export -f git
}

teardown() {
  cd "$ORIGINAL_PWD"
  rm -rf "$TEST_DIR"
}

# --- Tests ---

@test "Change Detection: FORCE_FULL_SCAN=true triggers FULL mode" {
  export FORCE_FULL_SCAN="true"
  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"

  # 1. Run the script
  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  
  # 2. Verify the ENV FILE content
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=FULL"* ]]
  [[ "$output" == *"FULL_SCAN=true"* ]]
}

@test "Change Detection: Missing BASE_SHA triggers FULL mode (Fallback)" {
  unset CI_MERGE_REQUEST_DIFF_BASE_SHA
  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=FULL"* ]]
}

@test "Change Detection: SKIP mode (Only Documentation changed)" {
  export MOCK_GIT_DIFF="README.md"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=SKIP"* ]]
  [[ "$output" == *"SKIP_SCAN=true"* ]]
}

@test "Change Detection: FULL mode (CI Config changed)" {
  export MOCK_GIT_DIFF=".gitlab-ci.yml"
  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=FULL"* ]]
}

@test "Change Detection: PARTIAL mode (Single component changed)" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/ingress-nginx"
  export MOCK_GIT_DIFF="components/ingress-nginx/values.yaml"

  # 1. Run script and check STDOUT for component detection
  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  # Check if script printed the component name to stdout
  [[ "$output" == *"ingress-nginx"* ]]

  # 2. Check ENV FILE for mode
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=PARTIAL"* ]]
  [[ "$output" == *"CHANGED_COMPONENTS_COUNT=1"* ]]
}

@test "Change Detection: PARTIAL mode (Multiple components changed)" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/app-A"
  mkdir -p "$GITOPS_COMPONENTS_DIR/app-B"
  
  export MOCK_GIT_DIFF=$(printf "components/app-A/values.yaml\ncomponents/app-B/Chart.yaml")

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  # Check STDOUT
  [[ "$output" == *"app-A"* ]]
  [[ "$output" == *"app-B"* ]]
  
  # Check ENV FILE
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=PARTIAL"* ]]
  [[ "$output" == *"CHANGED_COMPONENTS_COUNT=2"* ]]
}

@test "Change Detection: Mixed changes (Component + Core) triggers FULL" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/app-A"
  export MOCK_GIT_DIFF=$(printf "components/app-A/values.yaml\n.gitlab-ci.yml")

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  
  run cat "$OUT_DIR/scan-mode.env"
  [[ "$output" == *"SCAN_MODE=FULL"* ]]
}