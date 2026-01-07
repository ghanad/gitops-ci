#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/validate_kyverno.sh"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export OUT_DIR="$TEST_DIR/out"
  export RENDERED_DIR="$TEST_DIR/rendered"
  mkdir -p "$OUT_DIR" "$RENDERED_DIR"

  BIN_DIR="$TEST_DIR/bin"
  mkdir -p "$BIN_DIR"
  PATH="$BIN_DIR:$PATH"

  cat <<'SH' > "$BIN_DIR/kyverno"
#!/usr/bin/env bash
if [ "$1" = "apply" ]; then
  echo "policy-report"
  exit 0
fi
exit 0
SH
  chmod +x "$BIN_DIR/kyverno"

  cat <<'SH' > "$BIN_DIR/yq"
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$BIN_DIR/yq"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "validate_kyverno: fails when requested policy set is missing in strict mode" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
YAML

  export KYVERNO_POLICYSETS="nonexistent"
  export KYVERNO_STRICT_SETS="true"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 1 ]
}

@test "validate_kyverno: succeeds with baseline policies" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
YAML

  export KYVERNO_POLICYSETS="baseline"
  export KYVERNO_STRICT_SETS="true"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/kyverno-policy-report.txt" ]
}
