#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/sanity_application_prefix.sh"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export GITOPS_COMPONENTS_DIR="$TEST_DIR/components"
  export OUT_DIR="$TEST_DIR/out"
  mkdir -p "$GITOPS_COMPONENTS_DIR" "$OUT_DIR"

  function check_required_tools() {
    return 0
  }
  export -f check_required_tools
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "sanity_prefix: Skips when prefix variable is not set" {
  unset APP_NAME_PREFIX
  unset GITOPS_APPLICATION_NAME_PREFIX

  run bash "$SCRIPT_TO_TEST"

  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Skipping Application Prefix Check" ]]
}

@test "sanity_prefix: Skips when prefix variable is empty" {
  export APP_NAME_PREFIX=""
  unset GITOPS_APPLICATION_NAME_PREFIX

  run bash "$SCRIPT_TO_TEST"

  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Skipping Application Prefix Check" ]]
}

@test "sanity_prefix: Passes when all Application names match prefix" {
  export APP_NAME_PREFIX="cluster-a"

  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"
  cat <<'YAML' > "$GITOPS_COMPONENTS_DIR/app1/application.yml"
kind: Application
metadata:
  name: cluster-a-prometheus
YAML

  run bash "$SCRIPT_TO_TEST"

  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PREFIX CHECK PASSED" ]]
}

@test "sanity_prefix: Fails when Application name does not match prefix" {
  export APP_NAME_PREFIX="cluster-b"

  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"
  cat <<'YAML' > "$GITOPS_COMPONENTS_DIR/app1/application.yml"
kind: Application
metadata:
  name: cluster-a-prometheus
YAML

  run bash "$SCRIPT_TO_TEST"

  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "PREFIX_VIOLATION" ]]
}

@test "sanity_prefix: Ignores non-Application documents" {
  export APP_NAME_PREFIX="cluster-c"

  mkdir -p "$GITOPS_COMPONENTS_DIR/app1"
  cat <<'YAML' > "$GITOPS_COMPONENTS_DIR/app1/application.yml"
kind: ConfigMap
metadata:
  name: unrelated
YAML

  run bash "$SCRIPT_TO_TEST"

  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PREFIX CHECK PASSED" ]]
}
