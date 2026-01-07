#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/validate_kubeconform.sh"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export OUT_DIR="$TEST_DIR/out"
  export RENDERED_DIR="$TEST_DIR/rendered"
  export KUBERNETES_VERSION="1.27.0"
  export KUBECONFORM_SCHEMA_DIR="$TEST_DIR/schemas"

  mkdir -p "$OUT_DIR" "$RENDERED_DIR" "$KUBECONFORM_SCHEMA_DIR/v${KUBERNETES_VERSION}-standalone-strict"

  function check_required_tools() {
    return 0
  }
  export -f check_required_tools

  function kubeconform() {
    echo "Summary:"
    echo "  Passed: 1"
    return 0
  }
  export -f kubeconform
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "validate_kubeconform: exits cleanly when no manifests exist" {
  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  run grep -c "tests=\"0\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: validates rendered manifests" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  run grep -c "testcase name=\"app\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: handles manifests without document separator" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
YAML

  cat <<'YAML' > "$RENDERED_DIR/worker.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  run grep -c "testcase name=\"app\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "testcase name=\"worker\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}
