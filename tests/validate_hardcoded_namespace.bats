#!/usr/bin/env bats

load_lib() {
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/validate_hardcoded_namespace.sh"
}

setup() {
  load_lib

  TEST_DIR=$(mktemp -d)
  export OUT_DIR="$TEST_DIR/out"
  export RENDERED_DIR="$TEST_DIR/rendered"

  mkdir -p "$OUT_DIR" "$RENDERED_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "validate_hardcoded_namespace: passes for compliant resources and opt-out" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
---
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  namespace: ignored
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-one
  namespace: argocd
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.com
  namespace: ignored
---
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: Service
    metadata:
      name: svc
  - apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: opted-out
      namespace: legacy
      annotations:
        gitops.mahsan.net/allow-hardcoded-namespace: "true"
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/namespace-junit.xml" ]
  run grep -c "tests=\"1\"" "$OUT_DIR/namespace-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_hardcoded_namespace: fails when hardcoded namespaces are present" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
---
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: bad-config
      namespace: default
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 1 ]
  [ -f "$OUT_DIR/namespace-junit.xml" ]
  run grep -c "failures=\"1\"" "$OUT_DIR/namespace-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "hardcoded namespace" "$OUT_DIR/namespace-junit.xml"
  [ "$status" -eq 0 ]
}
