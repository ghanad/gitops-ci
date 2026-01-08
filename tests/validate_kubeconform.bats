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

@test "validate_kubeconform: validates two rendered manifests with leading separators" {
  cat <<'YAML' > "$RENDERED_DIR/app.yaml"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
data:
  key: value
YAML

  cat <<'YAML' > "$RENDERED_DIR/service.yaml"
---
apiVersion: v1
kind: Service
metadata:
  name: app-service
spec:
  ports:
  - port: 80
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify both files were processed
  run grep -c "testcase name=\"app\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "testcase name=\"service\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  
  # Verify total test count is 2
  run grep -c "tests=\"2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: validates two manifests without leading separators" {
  # First manifest without leading separator
  cat <<'YAML' > "$RENDERED_DIR/configmap.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
data:
  key: value
YAML

  # Second manifest without leading separator
  cat <<'YAML' > "$RENDERED_DIR/secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: secret1
type: Opaque
data:
  password: cGFzc3dvcmQ=
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify both files were processed
  run grep -c "testcase name=\"configmap\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "testcase name=\"secret\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  
  # Verify total test count is 2
  run grep -c "tests=\"2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: validates multiple manifests with mixed separators" {
  # Manifest with leading separator
  cat <<'YAML' > "$RENDERED_DIR/with-separator.yaml"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config1
data:
  env: prod
YAML

  # Manifest without leading separator
  cat <<'YAML' > "$RENDERED_DIR/without-separator.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: secret1
type: Opaque
YAML

  # Multi-document manifest with separators
  cat <<'YAML' > "$RENDERED_DIR/multi-doc.yaml"
---
apiVersion: v1
kind: Service
metadata:
  name: svc1
spec:
  ports:
  - port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: app
        image: nginx
YAML

  # Fourth manifest without separator
  cat <<'YAML' > "$RENDERED_DIR/deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test2
  template:
    metadata:
      labels:
        app: test2
    spec:
      containers:
      - name: app
        image: nginx:latest
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify all four files were processed
  run grep -c "testcase name" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  [ "$output" -eq 4 ]
  
  # Verify total test count is 4
  run grep -c "tests=\"4\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: handles two empty manifest files" {
  touch "$RENDERED_DIR/empty1.yaml"
  touch "$RENDERED_DIR/empty2.yaml"

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify both empty files were processed
  run grep -c "testcase name=\"empty1\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "testcase name=\"empty2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  
  # Verify total test count is 2
  run grep -c "tests=\"2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: fails when kubeconform reports errors on one of two manifests" {
  # Valid manifest
  cat <<'YAML' > "$RENDERED_DIR/valid.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: valid-config
data:
  key: value
YAML

  # Invalid manifest
  cat <<'YAML' > "$RENDERED_DIR/invalid.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: invalid-config
YAML

  # Override kubeconform to fail only for invalid.yaml
  function kubeconform() {
    local manifest_file="${@: -1}"
    if [[ "$manifest_file" == *"invalid.yaml"* ]]; then
      echo "Error: invalid resource" >&2
      return 1
    else
      echo "Summary:"
      echo "  Passed: 1"
      return 0
    fi
  }
  export -f kubeconform

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 1 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify both files were processed
  run grep "testcase name=\"valid\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep "testcase name=\"invalid\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  
  # Verify one failure exists (count occurrences of failure tag)
  failure_count=$(grep -o "<failure" "$OUT_DIR/validate-junit.xml" | wc -l)
  [ "$failure_count" -eq 1 ]
  
  # Verify total test count is 2 with 1 failure
  run grep "tests=\"2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep "failures=\"1\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}

@test "validate_kubeconform: validates real-world ArgoCD application manifests" {
  # ArgoCD Application without leading separator
  cat <<'YAML' > "$RENDERED_DIR/app-backend.yaml"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backend-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/example/app
    targetRevision: main
    path: manifests/backend
  destination:
    server: https://kubernetes.default.svc
    namespace: production
YAML

  # ArgoCD AppProject with leading separator
  cat <<'YAML' > "$RENDERED_DIR/project.yaml"
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production project
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
YAML

  run bash "$SCRIPT_TO_TEST"
  [ "$status" -eq 0 ]
  [ -f "$OUT_DIR/validate-junit.xml" ]
  
  # Verify both ArgoCD manifests were processed
  run grep -c "testcase name=\"app-backend\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  run grep -c "testcase name=\"project\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
  
  # Verify total test count is 2
  run grep -c "tests=\"2\"" "$OUT_DIR/validate-junit.xml"
  [ "$status" -eq 0 ]
}