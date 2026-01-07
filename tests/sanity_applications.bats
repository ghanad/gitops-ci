#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/sanity_applications.sh"
}

setup() {
  load_lib
  
  # Create an isolated environment for file creation
  TEST_DIR=$(mktemp -d)
  export GITOPS_COMPONENTS_DIR="$TEST_DIR/components"
  export OUT_DIR="$TEST_DIR/out"
  mkdir -p "$GITOPS_COMPONENTS_DIR" "$OUT_DIR"
  
  # Mock 'check_required_tools' to avoid dependency errors during testing
  # We override the function to always return true (0)
  function check_required_tools() {
    return 0
  }
  export -f check_required_tools
}

teardown() {
  # Cleanup temp directory
  rm -rf "$TEST_DIR"
}

# --- Tests ---

@test "sanity_app: Passes with valid unique applications" {
  # Setup App 1
  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"
  echo "metadata: { name: app-one }" > "$GITOPS_COMPONENTS_DIR/app1/application.yml"
  
  # Setup App 2
  mkdir -p "$GITOPS_COMPONENTS_DIR/app2"
  echo "metadata: { name: app-two }" > "$GITOPS_COMPONENTS_DIR/app2/application.yml"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "SANITY CHECKS PASSED" ]]
}

@test "sanity_app: Fails when metadata.name is missing" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/bad-app"
  # Create a file without metadata.name
  echo "spec: { destination: local }" > "$GITOPS_COMPONENTS_DIR/bad-app/application.yml"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Missing metadata.name" ]]
}

@test "sanity_app: Fails when duplicate Application names exist" {
  # App 1 -> name: my-app
  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"
  echo "metadata: { name: my-app }" > "$GITOPS_COMPONENTS_DIR/app1/application.yml"
  
  # App 2 -> name: my-app (Duplicate!)
  mkdir -p "$GITOPS_COMPONENTS_DIR/app2"
  echo "metadata: { name: my-app }" > "$GITOPS_COMPONENTS_DIR/app2/application.yml"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Duplicate Application name" ]]
}

@test "sanity_app: Fails when file extension is .yaml instead of .yml" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/wrong-ext"
  # Enforce .yml extension convention
  echo "metadata: { name: ok }" > "$GITOPS_COMPONENTS_DIR/wrong-ext/application.yaml"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Wrong extension detected" ]]
}