#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPT_TO_TEST="$PROJECT_ROOT/gitlab-ci-scripts/check_no_hardcoded_namespace.py"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export OUT_DIR="$TEST_DIR/out"
  export RENDERED_DIR="$TEST_DIR/rendered"
  export COMPONENTS_DIR="$TEST_DIR/components"

  mkdir -p "$OUT_DIR" "$RENDERED_DIR" "$COMPONENTS_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "check_no_hardcoded_namespace: passes for namespaced resources without metadata.namespace" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 1
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR" --junit "$OUT_DIR/namespace-junit.xml"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/namespace-junit.xml" ]
  run grep -c "failures=\"0\"" "$OUT_DIR/namespace-junit.xml"
  [ "$status" -eq 0 ]
}

@test "check_no_hardcoded_namespace: ignores cluster-scoped kinds with namespace set" {
  cat <<'YAML' > "$RENDERED_DIR/cluster.yaml"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: viewer
  namespace: should-not-matter
rules: []
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 0 ]
}

@test "check_no_hardcoded_namespace: allows Namespace and ArgoCD Application kinds" {
  cat <<'YAML' > "$RENDERED_DIR/allowed.yaml"
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  namespace: ignore-me
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app
  namespace: argocd
spec: {}
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 0 ]
}

@test "check_no_hardcoded_namespace: handles List kinds with compliant items" {
  cat <<'YAML' > "$RENDERED_DIR/list.yaml"
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cfg
    data:
      key: value
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 0 ]
}

@test "check_no_hardcoded_namespace: fails on hardcoded namespace in namespaced resource" {
  cat <<'YAML' > "$RENDERED_DIR/bad.yaml"
apiVersion: v1
kind: Service
metadata:
  name: svc
  namespace: prod
spec:
  ports:
  - port: 80
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Hardcoded namespace detected"* ]]
  [[ "$output" == *"namespace=prod"* ]]
}

@test "check_no_hardcoded_namespace: fails on List item with hardcoded namespace" {
  cat <<'YAML' > "$RENDERED_DIR/list-bad.yaml"
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cfg
      namespace: prod
    data:
      key: value
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc 1 item 1"* ]]
}

@test "check_no_hardcoded_namespace: reports multiple offending documents" {
  cat <<'YAML' > "$RENDERED_DIR/multi.yaml"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cfg1
  namespace: prod
data:
  k: v
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy1
  namespace: prod
spec:
  replicas: 1
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ConfigMap/cfg1"* ]]
  [[ "$output" == *"Deployment/deploy1"* ]]
}

@test "check_no_hardcoded_namespace: honors component opt-out via .gate.yml" {
  mkdir -p "$COMPONENTS_DIR/skipme"
  cat <<'YAML' > "$COMPONENTS_DIR/skipme/.gate.yml"
allowHardcodedNamespace: true
YAML

  cat <<'YAML' > "$RENDERED_DIR/skipme.yaml"
apiVersion: v1
kind: Service
metadata:
  name: svc
  namespace: prod
spec:
  ports:
  - port: 80
YAML

  run python3 "$SCRIPT_TO_TEST" --input "$RENDERED_DIR" --components-dir "$COMPONENTS_DIR"
  [ "$status" -eq 0 ]
}
