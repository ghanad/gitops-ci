#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/render_helm.sh"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export GITOPS_COMPONENTS_DIR="$TEST_DIR/components"
  export OUT_DIR="$TEST_DIR/out"
  export RENDERED_DIR="$TEST_DIR/rendered"
  export CI_PROJECT_DIR="$TEST_DIR"

  mkdir -p "$GITOPS_COMPONENTS_DIR" "$OUT_DIR" "$RENDERED_DIR"

  function check_required_tools() {
    return 0
  }
  export -f check_required_tools

  function helm() {
    if [ "$1" = "template" ]; then
      echo "---"
      echo "kind: ConfigMap"
    fi
    return 0
  }
  export -f helm

  function yq() {
    local query
    local file

    if [ "$1" = "eval" ]; then
      shift
    fi

    if [ "$1" = "-r" ]; then
      shift
    fi

    query="$1"
    file="$2"

    case "$query" in
      ".metadata.name"*)
        awk '/name:/ { print $2; exit }' "$file"
        ;;
      ".spec.destination.namespace"*)
        awk '/namespace:/ { print $2; exit }' "$file"
        ;;
      ".spec.source.path"*)
        awk '/path:/ { print $2; exit }' "$file"
        ;;
      ".")
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }
  export -f yq
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_helm: fails when target components file is missing" {
  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 1 ]
}

@test "render_helm: renders raw manifests into a combined output" {
  mkdir -p "$GITOPS_COMPONENTS_DIR/raw-app/manifests"
  cat <<'APP' > "$GITOPS_COMPONENTS_DIR/raw-app/application.yml"
metadata:
  name: raw-app
spec:
  destination:
    namespace: default
  source:
    path: manifests
APP

  cat <<'YAML' > "$GITOPS_COMPONENTS_DIR/raw-app/manifests/one.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: one
YAML

  cat <<'YAML' > "$GITOPS_COMPONENTS_DIR/raw-app/manifests/two.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: two
YAML

  echo "raw-app" > "$OUT_DIR/target_components.txt"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]

  [ -f "$RENDERED_DIR/raw-app.yaml" ]
  run grep -c "kind: ConfigMap" "$RENDERED_DIR/raw-app.yaml"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}
