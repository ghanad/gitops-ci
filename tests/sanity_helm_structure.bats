#!/usr/bin/env bats

# --- Setup & Helper Functions ---

load_lib() {
  # Locate the project root based on the test file location
  # Assumes structure:
  #   .
  #   ├── gitlab-ci-scripts/
  #   └── tests/
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  SCRIPT_TO_TEST="$SCRIPTS_DIR/sanity_helm_structure.sh"
}

setup() {
  load_lib
  
  # Create an isolated temporary environment for each test
  TEST_DIR=$(mktemp -d)
  
  # Set environment variables required by the script
  export GITOPS_COMPONENTS_DIR="$TEST_DIR/components"
  export OUT_DIR="$TEST_DIR/out"
  mkdir -p "$GITOPS_COMPONENTS_DIR" "$OUT_DIR"
  
  # Ensure lib.sh is accessible to the script (mocking the real structure)
  if [ ! -f "$SCRIPTS_DIR/lib.sh" ]; then
    echo "Error: lib.sh not found in $SCRIPTS_DIR"
    exit 1
  fi
}

teardown() {
  # Cleanup temporary files after each test
  rm -rf "$TEST_DIR"
}

# Helper to create a dummy Helm component structure
create_helm_component() {
  local name=$1
  local comp_dir="$GITOPS_COMPONENTS_DIR/$name"
  mkdir -p "$comp_dir"
  
  # Create Chart.yaml
  cat <<EOF > "$comp_dir/Chart.yaml"
apiVersion: v2
name: $name
version: 1.0.0
dependencies:
  - name: redis
    version: 1.0.0
    alias: my-redis-alias
    repository: https://charts.bitnami.com/bitnami
EOF
}

# Helper to create values.yaml content
create_values() {
  local name=$1
  local content=$2
  echo "$content" > "$GITOPS_COMPONENTS_DIR/$name/values.yaml"
}

# ==========================================
# TEST CASES
# ==========================================

@test "Success: Correct alias used in values.yaml" {
  create_helm_component "app-correct"
  # The key in values.yaml matches the alias defined in Chart.yaml
  create_values "app-correct" "my-redis-alias: {}"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "HELM STRUCTURE CHECKS PASSED" ]]
}

@test "Failure: Dependency defined but values.yaml is missing" {
  create_helm_component "app-no-values"
  # We intentionally do not create values.yaml

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "values.yaml missing" ]]
}

@test "Failure: Alias defined in Chart but missing in values (Fail Fast)" {
  create_helm_component "app-missing-key"
  # The required alias key is missing entirely
  create_values "app-missing-key" "other-key: {}"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "MISSING in values.yaml" ]]
  [[ "$output" =~ "my-redis-alias" ]]
}

@test "Failure: Using original 'name' instead of 'alias' in values (Common Mistake)" {
  create_helm_component "app-wrong-name"
  # User used 'redis' (chart name) instead of 'my-redis-alias' (required alias)
  create_values "app-wrong-name" "redis: {}"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "MISSING in values.yaml" ]]
  [[ "$output" =~ "my-redis-alias" ]]
}

@test "Ignore: Raw manifest component (No Chart.yaml) should be skipped" {
  # Create a component that looks like raw manifests
  mkdir -p "$GITOPS_COMPONENTS_DIR/raw-app"
  touch "$GITOPS_COMPONENTS_DIR/raw-app/application.yml"
  mkdir -p "$GITOPS_COMPONENTS_DIR/raw-app/manifests"
  
  # Create a dummy values.yaml to prove it's ignored if Chart.yaml is missing
  echo "invalid: yaml" > "$GITOPS_COMPONENTS_DIR/raw-app/values.yaml"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 0 ]
  # Ensure the script didn't try to validate 'raw-app'
  [[ ! "$output" =~ "raw-app" ]]
}

@test "Logic: Prioritize Alias over Name" {
  local comp_dir="$GITOPS_COMPONENTS_DIR/app-no-alias"
  mkdir -p "$comp_dir"
  
  # Create a chart dependency WITHOUT an alias
  cat <<EOF > "$comp_dir/Chart.yaml"
apiVersion: v2
name: app-no-alias
dependencies:
  - name: postgresql
EOF

  # Logic should fallback to using the name 'postgresql'
  create_values "app-no-alias" "postgresql: {}"

  run bash "$SCRIPT_TO_TEST"
  
  echo "Output: $output"
  [ "$status" -eq 0 ]
}