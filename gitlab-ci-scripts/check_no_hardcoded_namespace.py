#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, Iterable, List, Optional
from xml.sax.saxutils import escape as xml_escape


ALLOWED_NAMESPACE_KINDS = {"Namespace", "Application", "AppProject"}


def log_info(message: str) -> None:
    print(f"ℹ️  {message}", file=sys.stderr)


def log_success(message: str) -> None:
    print(f"✅ {message}", file=sys.stderr)


def log_warning(message: str) -> None:
    print(f"⚠️  {message}", file=sys.stderr)


def log_error(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)


def run_yq_json(args: List[str]) -> Any:
    try:
        result = subprocess.run(
            ["yq", "eval", "-o=json"] + args,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        raise RuntimeError(f"yq failed: {stderr or exc}") from exc
    if not result.stdout.strip():
        return None
    return json.loads(result.stdout)


def load_yaml_documents(path: str) -> List[Any]:
    data = run_yq_json(["-s", ".", path])
    if data is None:
        return []
    if not isinstance(data, list):
        return [data]
    return data


def load_cluster_scoped_kinds(path: str) -> List[str]:
    kinds: List[str] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            kinds.append(stripped)
    return kinds


def load_component_allow_flag(component_dir: str) -> bool:
    gate_file = os.path.join(component_dir, ".gate.yml")
    if not os.path.isfile(gate_file):
        return False
    try:
        data = run_yq_json([gate_file])
    except RuntimeError as exc:
        log_warning(f"Unable to read {gate_file}: {exc}")
        return False
    if isinstance(data, dict) and data.get("allowHardcodedNamespace") is True:
        return True
    return False


def iter_objects(
    document: Any,
    document_index: int,
    item_index: Optional[int] = None,
) -> Iterable[Dict[str, Any]]:
    if not isinstance(document, dict):
        return
    kind = document.get("kind")
    if kind == "List" and isinstance(document.get("items"), list):
        for idx, item in enumerate(document["items"], start=1):
            yield from iter_objects(item, document_index, idx)
        return
    yield {
        "object": document,
        "document_index": document_index,
        "item_index": item_index,
    }


def namespace_value(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    text = str(value).strip()
    return text or None


def check_manifest(
    component: str,
    manifest_path: str,
    cluster_scoped_kinds: set,
) -> List[Dict[str, Any]]:
    violations: List[Dict[str, Any]] = []
    documents = load_yaml_documents(manifest_path)
    for doc_index, document in enumerate(documents, start=1):
        if document in (None, {}, []):
            continue
        for entry in iter_objects(document, doc_index):
            obj = entry["object"]
            kind = obj.get("kind")
            if not kind:
                continue
            if kind in ALLOWED_NAMESPACE_KINDS:
                continue
            if kind in cluster_scoped_kinds:
                continue

            metadata = obj.get("metadata") or {}
            ns_value = namespace_value(metadata.get("namespace"))
            if ns_value is None:
                continue

            violations.append(
                {
                    "component": component,
                    "manifest": manifest_path,
                    "document_index": entry["document_index"],
                    "item_index": entry["item_index"],
                    "namespace": ns_value,
                    "kind": kind,
                    "apiVersion": obj.get("apiVersion", "<unknown>"),
                    "name": metadata.get("name", "<unknown>"),
                }
            )
    return violations


def junit_header(suite_name: str, tests: int, failures: int, duration: float) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<testsuite name="{xml_escape(suite_name)}" tests="{tests}" '
        f'failures="{failures}" time="{duration:.2f}">\n'
    )


def junit_testcase(name: str, status: str, message: str, duration: float) -> str:
    escaped_name = xml_escape(name)
    output = f'  <testcase name="{escaped_name}" classname="validation" time="{duration:.2f}">\n'
    if status == "failed":
        escaped_msg = xml_escape(message)
        output += f'    <failure message="Validation failed">{escaped_msg}</failure>\n'
    output += "  </testcase>\n"
    return output


def junit_footer() -> str:
    return "</testsuite>\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fail when namespaced resources hardcode metadata.namespace in rendered outputs."
    )
    parser.add_argument(
        "--input",
        required=True,
        help="Rendered manifest file or directory to scan (rendered/).",
    )
    parser.add_argument(
        "--components-dir",
        default="components",
        help="Components directory containing optional .gate.yml files.",
    )
    parser.add_argument(
        "--cluster-scoped-kinds",
        default=os.path.join(os.path.dirname(__file__), "cluster_scoped_kinds.txt"),
        help="Path to cluster-scoped kinds allowlist.",
    )
    parser.add_argument(
        "--junit",
        default=None,
        help="Write JUnit XML report to this path.",
    )
    args = parser.parse_args()

    if shutil.which("yq") is None:
        log_error("Required tool not found: yq")
        return 1

    if not os.path.exists(args.input):
        log_error(f"Input path not found: {args.input}")
        return 1

    try:
        cluster_scoped_kinds = set(load_cluster_scoped_kinds(args.cluster_scoped_kinds))
    except OSError as exc:
        log_error(f"Failed to read cluster-scoped allowlist: {exc}")
        return 1

    if os.path.isdir(args.input):
        manifest_files = sorted(
            [
                os.path.join(args.input, entry)
                for entry in os.listdir(args.input)
                if entry.endswith(".yaml") or entry.endswith(".yml")
            ]
        )
    else:
        manifest_files = [args.input]

    if not manifest_files:
        log_info("No rendered manifests found. Nothing to validate.")
        return 0

    log_info(f"Found {len(manifest_files)} manifest file(s) to validate.")

    total_failures = 0
    junit_results: List[str] = []
    start_time = time.time()

    for manifest_path in manifest_files:
        component_name = os.path.splitext(os.path.basename(manifest_path))[0]
        component_dir = os.path.join(args.components_dir, component_name)
        component_start = time.time()
        component_failures: List[Dict[str, Any]] = []

        if load_component_allow_flag(component_dir):
            log_info(f"Skipping {component_name}: allowHardcodedNamespace enabled.")
        else:
            try:
                component_failures = check_manifest(
                    component_name, manifest_path, cluster_scoped_kinds
                )
            except RuntimeError as exc:
                log_error(f"Failed to parse {manifest_path}: {exc}")
                component_failures = [
                    {
                        "component": component_name,
                        "manifest": manifest_path,
                        "document_index": 0,
                        "item_index": None,
                        "namespace": "unknown",
                        "kind": "unknown",
                        "apiVersion": "unknown",
                        "name": "unknown",
                        "error": str(exc),
                    }
                ]

        component_time = time.time() - component_start
        if component_failures:
            total_failures += 1
            log_error(f"Hardcoded namespace detected in {component_name}:")
            for violation in component_failures:
                location = f"doc {violation['document_index']}"
                if violation.get("item_index"):
                    location += f" item {violation['item_index']}"
                detail = (
                    f"{violation['apiVersion']}/{violation['kind']}/{violation['name']}"
                    f" namespace={violation['namespace']}"
                )
                log_error(
                    f"  - {detail} | file={violation['manifest']} | {location}"
                )
            message = "; ".join(
                [
                    f"{v['apiVersion']}/{v['kind']}/{v['name']} "
                    f"(namespace={v['namespace']}, {v['manifest']} doc {v['document_index']}"
                    + (f" item {v['item_index']}" if v.get("item_index") else "")
                    + ")"
                    for v in component_failures
                ]
            )
            junit_results.append(
                junit_testcase(component_name, "failed", message, component_time)
            )
        else:
            log_success(f"{component_name}: no hardcoded namespaces found.")
            junit_results.append(
                junit_testcase(component_name, "passed", "", component_time)
            )

    duration = time.time() - start_time
    if args.junit:
        junit_dir = os.path.dirname(args.junit)
        if junit_dir:
            os.makedirs(junit_dir, exist_ok=True)
        with open(args.junit, "w", encoding="utf-8") as handle:
            handle.write(junit_header("namespace-gate", len(manifest_files), total_failures, duration))
            handle.writelines(junit_results)
            handle.write(junit_footer())

    if total_failures:
        log_error("Hardcoded namespace validation failed.")
        return 1
    log_success("Hardcoded namespace validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
