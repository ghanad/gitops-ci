#!/usr/bin/env bats

load_lib() {
  # Locate the project root relative to this test file
  PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd )"
  SCRIPTS_DIR="$PROJECT_ROOT/gitlab-ci-scripts"
  
  # Source the library file to test its functions directly
  source "$SCRIPTS_DIR/lib.sh"
}

setup() {
  load_lib
}

# --- Unit Tests for xml_escape ---

@test "lib.sh: xml_escape escapes special characters correctly" {
  run xml_escape '<test>&"quote"'
  [ "$output" = "&lt;test&gt;&amp;&quot;quote&quot;" ]
}

@test "lib.sh: xml_escape handles normal strings" {
  run xml_escape "hello-world"
  [ "$output" = "hello-world" ]
}

# --- Unit Tests for normalize_source_dir (Security Critical) ---

@test "lib.sh: normalize_source_dir allows dot (.)" {
  run normalize_source_dir "/app" "."
  [ "$output" = "/app" ]
  [ "$status" -eq 0 ]
}

@test "lib.sh: normalize_source_dir handles subdirectories" {
  run normalize_source_dir "/app" "./manifests"
  [ "$output" = "/app/manifests" ]
  [ "$status" -eq 0 ]
}

@test "lib.sh: normalize_source_dir handles raw folder names" {
  run normalize_source_dir "/app" "manifests"
  [ "$output" = "/app/manifests" ]
  [ "$status" -eq 0 ]
}

@test "lib.sh: normalize_source_dir BLOCKS parent directory traversal (..)" {
  # This prevents path traversal attacks (e.g., accessing secrets outside the app dir)
  run normalize_source_dir "/app" "../secrets"
  
  # Should return non-zero status (failure)
  [ "$status" -eq 1 ]
}

@test "lib.sh: normalize_source_dir BLOCKS absolute paths" {
  run normalize_source_dir "/app" "/etc/passwd"
  [ "$status" -eq 1 ]
}

# --- Unit Tests for get_app_metadata ---

@test "lib.sh: get_app_metadata extracts fields correctly" {
  # Create a temporary YAML file for testing
  TMP_YAML=$(mktemp)
  echo "metadata:" > "$TMP_YAML"
  echo "  name: my-app" >> "$TMP_YAML"
  
  run get_app_metadata "$TMP_YAML" "metadata.name"
  [ "$output" = "my-app" ]
  
  rm "$TMP_YAML"
}

@test "lib.sh: get_app_metadata returns empty string for missing fields" {
  TMP_YAML=$(mktemp)
  echo "metadata: {}" > "$TMP_YAML"
  
  run get_app_metadata "$TMP_YAML" "spec.source"
  [ "$output" = "" ]
  
  rm "$TMP_YAML"
}