"""Validate canonical Core ABI manifests and receipt input provenance."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence

from core_ffi_receipt_common import (
    ABI_TOOL_PATHS,
    BUILD_INPUT_TOOL,
    IDENTIFIER,
    RECEIPT_TOOL_PATHS,
    ROOT,
    SHA256,
    ReceiptError,
    canonical,
    digest,
    digest_file_set,
    exact_object,
    fail,
    nonempty_text,
    parse_json,
)


def _validate_type(value: Any, code: str) -> None:
    record = exact_object(value, {"canonical", "spelled"}, code)
    nonempty_text(record["canonical"], code)
    nonempty_text(record["spelled"], code)


def validate_manifest_shape(
    document: Any,
    *,
    target: str,
    variant: str,
) -> dict[str, Any]:
    manifest = exact_object(
        document,
        {"enums", "schemaVersion", "structs", "symbols", "target", "typedefs", "variant"},
        "abi-manifest-fields",
    )
    if type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
        fail("abi-manifest-schema")
    if manifest["target"] != target:
        fail("abi-manifest-target-binding")
    if manifest["variant"] != variant:
        fail("abi-manifest-variant-binding")

    symbols = manifest["symbols"]
    if not isinstance(symbols, list) or not symbols:
        fail("abi-manifest-symbols-empty")
    symbol_names: list[str] = []
    for symbol in symbols:
        record = exact_object(
            symbol,
            {
                "callingConvention",
                "linkage",
                "name",
                "parameters",
                "returnType",
                "signature",
                "visibility",
            },
            "abi-manifest-symbol-shape",
        )
        name = nonempty_text(record["name"], "abi-manifest-symbol-name")
        if not name.startswith("sc_") or not IDENTIFIER.fullmatch(name):
            fail("abi-manifest-symbol-name")
        symbol_names.append(name)
        for field in ("callingConvention", "linkage", "returnType", "signature", "visibility"):
            nonempty_text(record[field], "abi-manifest-symbol-shape")
        if not isinstance(record["parameters"], list):
            fail("abi-manifest-symbol-parameters")
        for parameter in record["parameters"]:
            _validate_type(parameter, "abi-manifest-symbol-parameter")
    if symbol_names != sorted(symbol_names) or len(symbol_names) != len(set(symbol_names)):
        fail("abi-manifest-symbol-order-or-duplicate")

    enums = manifest["enums"]
    if not isinstance(enums, list) or not enums:
        fail("abi-manifest-enums-empty")
    enum_names: list[str] = []
    enum_constants: set[str] = set()
    for enum in enums:
        record = exact_object(
            enum,
            {"name", "underlyingType", "values"},
            "abi-manifest-enum-shape",
        )
        enum_names.append(nonempty_text(record["name"], "abi-manifest-enum-name"))
        nonempty_text(record["underlyingType"], "abi-manifest-enum-type")
        values = record["values"]
        if not isinstance(values, list) or not values:
            fail("abi-manifest-enum-values")
        for item in values:
            constant = exact_object(
                item,
                {"name", "value"},
                "abi-manifest-enum-value-shape",
            )
            constant_name = nonempty_text(constant["name"], "abi-manifest-enum-value-name")
            if not IDENTIFIER.fullmatch(constant_name) or constant_name in enum_constants:
                fail("abi-manifest-enum-value-name")
            enum_constants.add(constant_name)
            if type(constant["value"]) is not int:
                fail("abi-manifest-enum-value")
    if enum_names != sorted(enum_names) or len(enum_names) != len(set(enum_names)):
        fail("abi-manifest-enum-order-or-duplicate")

    structs = manifest["structs"]
    if not isinstance(structs, list) or not structs:
        fail("abi-manifest-structs-empty")
    struct_names: list[str] = []
    for struct in structs:
        record = exact_object(
            struct,
            {"alignmentBytes", "fields", "name", "sizeBytes"},
            "abi-manifest-struct-shape",
        )
        name = nonempty_text(record["name"], "abi-manifest-struct-name")
        if not name.startswith("Sc") or not IDENTIFIER.fullmatch(name):
            fail("abi-manifest-struct-name")
        struct_names.append(name)
        if (
            type(record["alignmentBytes"]) is not int
            or record["alignmentBytes"] <= 0
            or type(record["sizeBytes"]) is not int
            or record["sizeBytes"] <= 0
        ):
            fail("abi-manifest-struct-layout")
        fields = record["fields"]
        if not isinstance(fields, list) or not fields:
            fail("abi-manifest-struct-fields")
        field_names: set[str] = set()
        previous_offset = -1
        for field in fields:
            item = exact_object(
                field,
                {"name", "offsetBytes", "type"},
                "abi-manifest-field-shape",
            )
            field_name = nonempty_text(item["name"], "abi-manifest-field-name")
            if not IDENTIFIER.fullmatch(field_name) or field_name in field_names:
                fail("abi-manifest-field-name")
            field_names.add(field_name)
            offset = item["offsetBytes"]
            if type(offset) is not int or offset < previous_offset or offset >= record["sizeBytes"]:
                fail("abi-manifest-field-offset")
            previous_offset = offset
            _validate_type(item["type"], "abi-manifest-field-type")
    if struct_names != sorted(struct_names) or len(struct_names) != len(set(struct_names)):
        fail("abi-manifest-struct-order-or-duplicate")

    typedefs = manifest["typedefs"]
    if not isinstance(typedefs, list) or not typedefs:
        fail("abi-manifest-typedefs-empty")
    typedef_names: list[str] = []
    for typedef in typedefs:
        record = exact_object(typedef, {"name", "type"}, "abi-manifest-typedef-shape")
        name = nonempty_text(record["name"], "abi-manifest-typedef-name")
        if not name.startswith("Sc") or not IDENTIFIER.fullmatch(name):
            fail("abi-manifest-typedef-name")
        typedef_names.append(name)
        _validate_type(record["type"], "abi-manifest-typedef-type")
    if typedef_names != sorted(typedef_names) or len(typedef_names) != len(set(typedef_names)):
        fail("abi-manifest-typedef-order-or-duplicate")
    return manifest


def run_checked(command: Sequence[str], code: str) -> str:
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
    except OSError as error:
        raise ReceiptError(code + ":unavailable") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"status-{result.returncode}"
        fail(code + ":" + detail.replace("\n", " | "))
    return result.stdout


def ensure_repository_abi_set_current() -> None:
    run_checked(
        [sys.executable, str(ROOT / "tools/core_abi_manifest.py"), "generate-set", "--check"],
        "abi-manifest-set-stale",
    )


def current_build_input_identity(*, require_clean: bool) -> str:
    command = [sys.executable, str(BUILD_INPUT_TOOL), "identity"]
    if require_clean:
        command.append("--require-clean")
    value = run_checked(command, "build-input-identity").strip()
    if not SHA256.fullmatch(value):
        fail("build-input-identity-shape")
    return value


def repository_manifest_bytes(target: str, variant: str) -> bytes:
    with tempfile.TemporaryDirectory(prefix="sc-core-receipt-manifest-") as directory:
        output = Path(directory) / "manifest.json"
        run_checked(
            [
                sys.executable,
                str(ROOT / "tools/core_abi_manifest.py"),
                "materialize",
                "--target",
                target,
                "--variant",
                variant,
                "--output",
                str(output),
            ],
            "abi-manifest-materialize",
        )
        return output.read_bytes()


def validate_abi_manifest(
    path: Path,
    *,
    target: str,
    variant: str,
    ensure_current: Callable[[], None] = ensure_repository_abi_set_current,
    materialize: Callable[[str, str], bytes] = repository_manifest_bytes,
) -> tuple[dict[str, Any], bytes]:
    if path.is_symlink() or not path.is_file():
        fail("abi-manifest-missing-or-symlink")
    raw = path.read_bytes()
    document = parse_json(raw, code="abi-manifest-json")
    if raw != canonical(document):
        fail("abi-manifest-not-canonical")
    manifest = validate_manifest_shape(document, target=target, variant=variant)
    ensure_current()
    if raw != materialize(target, variant):
        fail("abi-manifest-current-binding")
    return manifest, raw


def _abi_surface_set() -> list[Path]:
    surface_root = ROOT / "core/abi/surfaces-v1"
    if surface_root.is_symlink() or not surface_root.is_dir():
        fail("abi-surface-root-missing-or-symlink")
    return list(surface_root.glob("*.json"))


def expected_inputs(abi_manifest: Path) -> dict[str, str]:
    return {
        "abiHeaderSha256": digest(ROOT / "core/include/superconnect_core.h"),
        "abiIdentityHeaderSha256": digest(
            ROOT / "core/include/superconnect_core_abi_identity_v1.h"
        ),
        "abiManifestConfigSha256": digest(ROOT / "core/abi/manifest-config-v1.json"),
        # These legacy field names now bind the complete split implementation file sets.
        "abiManifestGeneratorSha256": digest_file_set(ABI_TOOL_PATHS),
        "abiManifestSha256": digest(abi_manifest),
        "abiMarkerGeneratorSha256": digest(ROOT / "core/build.rs"),
        "abiSurfaceSetSha256": digest_file_set(_abi_surface_set()),
        "abiSymbolBaselineSha256": digest(ROOT / "qa/baselines/product-symbols/core-abi.txt"),
        "buildInputToolSha256": digest(BUILD_INPUT_TOOL),
        "builderSha256": digest(ROOT / "tools/build-core-ffi.sh"),
        "cargoLockSha256": digest(ROOT / "core/Cargo.lock"),
        "cargoManifestSha256": digest(ROOT / "core/Cargo.toml"),
        "receiptToolSha256": digest_file_set(RECEIPT_TOOL_PATHS),
        "rustToolchainSha256": digest(ROOT / "rust-toolchain.toml"),
        "toolchainLockSha256": digest(ROOT / "release/TOOLCHAINS.lock.json"),
    }
