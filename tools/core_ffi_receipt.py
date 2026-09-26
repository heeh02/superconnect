#!/usr/bin/env python3
"""Create and verify a fixed-source receipt for one canonical Rust Core archive.

Toolchain authority: ``release/TOOLCHAINS.lock.json``.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

# This module is also loaded through importlib.spec_from_file_location by failure-injection tests.
# Make sibling helper imports deterministic in both that mode and normal CLI execution.
TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from core_ffi_archive_validator import (  # noqa: E402
    archive_members as _archive_members,
    llvm_nm_executable_name,
    marker_bytes,
    resolve_bash,
    resolve_nm,
    verify_archive_architecture,
    verify_archive_marker,
    verify_archive_symbols,
    windows_git_bash_candidates,
)
from core_ffi_manifest_validator import (  # noqa: E402
    current_build_input_identity,
    ensure_repository_abi_set_current,
    expected_inputs,
    repository_manifest_bytes,
    validate_abi_manifest as _validate_abi_manifest,
)
from core_ffi_receipt_common import (  # noqa: E402
    AR_HEADER_SIZE,
    AR_MAGIC,
    CONTRACT,
    MARKER_CONTRACT,
    ROOT,
    SHA1,
    SHA256,
    TARGET,
    UTC,
    ReceiptError,
    canonical,
    digest,
    digest_bytes,
    digest_file_set,
    fail,
    git,
    load_receipt,
    resolved_input,
    source_identity,
)


# Preserve the original import surface for existing callers and tests.
load = load_receipt


def validate_abi_manifest(
    path: Path,
    *,
    target: str,
    variant: str,
) -> tuple[dict[str, Any], bytes]:
    return _validate_abi_manifest(
        path,
        target=target,
        variant=variant,
        ensure_current=ensure_repository_abi_set_current,
        materialize=repository_manifest_bytes,
    )


def artifact_record(
    archive: Path,
    manifest: dict[str, Any],
    manifest_raw: bytes,
    *,
    target: str,
    profile: str,
    variant: str,
    source: dict[str, Any],
    build_input_sha256: str,
) -> dict[str, Any]:
    manifest_sha256 = digest_bytes(manifest_raw)
    expected_marker = marker_bytes(
        manifest_sha256=manifest_sha256,
        target=target,
        variant=variant,
        profile=profile,
        git_sha=source["gitSha"],
        git_tree=source["gitTree"],
        build_input_sha256=build_input_sha256,
        clean=True,
    )
    verify_archive_marker(archive, expected_marker)
    symbol_count, symbol_sha256 = verify_archive_symbols(archive, manifest)
    verify_archive_architecture(
        archive,
        target=target,
        profile=profile,
        variant=variant,
    )
    return {
        "abiBinding": {
            "contract": MARKER_CONTRACT,
            "buildInputSha256": build_input_sha256,
            "manifestSha256": manifest_sha256,
            "markerSha256": digest_bytes(expected_marker),
            "profile": profile,
            "sourceGitSha": source["gitSha"],
            "sourceTreeSha": source["gitTree"],
            "target": target,
            "variant": variant,
        },
        "architecture": {"status": "VERIFIED", "target": target},
        "file": archive.name,
        "sha256": digest(archive),
        "size": archive.stat().st_size,
        "symbols": {
            "count": symbol_count,
            "sha256": symbol_sha256,
            "status": "VERIFIED",
        },
    }


def validate_shape(value: dict[str, Any]) -> None:
    if set(value) != {"contract", "source", "build", "inputs", "artifact", "createdAtUtc"}:
        fail("receipt-fields")
    if value["contract"] != CONTRACT:
        fail("receipt-contract")
    source = value["source"]
    if not isinstance(source, dict) or set(source) != {"gitSha", "gitTree", "dirty"}:
        fail("source-fields")
    if not isinstance(source["gitSha"], str) or not SHA1.fullmatch(source["gitSha"]):
        fail("source-sha")
    if not isinstance(source["gitTree"], str) or not SHA1.fullmatch(source["gitTree"]):
        fail("source-tree")
    if source["dirty"] is not False:
        fail("source-dirty")
    build = value["build"]
    if not isinstance(build, dict) or set(build) != {
        "target",
        "profile",
        "variant",
        "rustVersion",
    }:
        fail("build-fields")
    if not isinstance(build["target"], str) or not TARGET.fullmatch(build["target"]):
        fail("build-target")
    if build["profile"] != "ffi-release" or build["variant"] not in {"full", "minimal"}:
        fail("build-mode")
    if build["rustVersion"] != "1.97.1":
        fail("build-rust-version")
    inputs = value["inputs"]
    expected_keys = {
        "abiHeaderSha256",
        "abiIdentityHeaderSha256",
        "abiManifestConfigSha256",
        "abiManifestGeneratorSha256",
        "abiManifestSha256",
        "abiMarkerGeneratorSha256",
        "abiSurfaceSetSha256",
        "abiSymbolBaselineSha256",
        "buildInputToolSha256",
        "builderSha256",
        "cargoLockSha256",
        "cargoManifestSha256",
        "receiptToolSha256",
        "rustToolchainSha256",
        "toolchainLockSha256",
    }
    if not isinstance(inputs, dict) or set(inputs) != expected_keys or any(
        not isinstance(item, str) or not SHA256.fullmatch(item) for item in inputs.values()
    ):
        fail("input-digests")
    artifact = value["artifact"]
    if not isinstance(artifact, dict) or set(artifact) != {
        "abiBinding",
        "architecture",
        "file",
        "sha256",
        "size",
        "symbols",
    }:
        fail("artifact-fields")
    if (
        not isinstance(artifact["file"], str)
        or "/" in artifact["file"]
        or artifact["file"] in {"", ".", ".."}
    ):
        fail("artifact-file")
    if not isinstance(artifact["sha256"], str) or not SHA256.fullmatch(artifact["sha256"]):
        fail("artifact-sha")
    if type(artifact["size"]) is not int or artifact["size"] <= 0:
        fail("artifact-size")
    architecture = artifact["architecture"]
    if architecture != {"status": "VERIFIED", "target": build["target"]}:
        fail("artifact-architecture")
    symbols = artifact["symbols"]
    if (
        not isinstance(symbols, dict)
        or set(symbols) != {"count", "sha256", "status"}
        or type(symbols["count"]) is not int
        or symbols["count"] <= 0
        or not isinstance(symbols["sha256"], str)
        or not SHA256.fullmatch(symbols["sha256"])
        or symbols["status"] != "VERIFIED"
    ):
        fail("artifact-symbols")
    binding = artifact["abiBinding"]
    if not isinstance(binding, dict) or set(binding) != {
        "buildInputSha256",
        "contract",
        "manifestSha256",
        "markerSha256",
        "profile",
        "sourceGitSha",
        "sourceTreeSha",
        "target",
        "variant",
    }:
        fail("artifact-abi-binding")
    if binding["contract"] != MARKER_CONTRACT:
        fail("artifact-marker-contract")
    if any(
        not isinstance(binding[key], str) or not SHA256.fullmatch(binding[key])
        for key in ("buildInputSha256", "manifestSha256", "markerSha256")
    ):
        fail("artifact-marker-digest")
    if (
        binding["profile"] != build["profile"]
        or binding["target"] != build["target"]
        or binding["variant"] != build["variant"]
        or binding["sourceGitSha"] != source["gitSha"]
        or binding["sourceTreeSha"] != source["gitTree"]
    ):
        fail("artifact-marker-metadata")
    if not isinstance(value["createdAtUtc"], str) or not UTC.fullmatch(value["createdAtUtc"]):
        fail("created-at")


def _validate_arguments(args: argparse.Namespace) -> None:
    if not TARGET.fullmatch(args.target):
        fail("build-target")
    if args.profile != "ffi-release":
        fail("build-profile-not-receiptable")
    if args.variant not in {"full", "minimal"}:
        fail("build-variant")


def create(args: argparse.Namespace) -> dict[str, Any]:
    _validate_arguments(args)
    archive = resolved_input(args.archive, "archive-missing-or-symlink")
    manifest = resolved_input(args.abi_manifest, "abi-manifest-missing-or-symlink")
    output = args.output
    if output.is_symlink() or not output.parent.is_dir() or output.parent.is_symlink():
        fail("output-must-be-new")
    if output.exists() and (not args.replace or not output.is_file()):
        fail("output-must-be-new")
    output = output.resolve()
    manifest_document, manifest_raw = validate_abi_manifest(
        manifest,
        target=args.target,
        variant=args.variant,
    )
    source = source_identity()
    if source["dirty"]:
        fail("source-not-clean")
    build_input_sha256 = current_build_input_identity(require_clean=True)
    input_record = expected_inputs(manifest)
    artifact = artifact_record(
        archive,
        manifest_document,
        manifest_raw,
        target=args.target,
        profile=args.profile,
        variant=args.variant,
        source=source,
        build_input_sha256=build_input_sha256,
    )
    source_after = source_identity()
    build_input_after = current_build_input_identity(require_clean=True)
    if source_after != source or build_input_after != build_input_sha256:
        fail("source-changed-during-receipt")
    value = {
        "contract": CONTRACT,
        "source": source,
        "build": {
            "target": args.target,
            "profile": args.profile,
            "variant": args.variant,
            "rustVersion": "1.97.1",
        },
        "inputs": input_record,
        "artifact": artifact,
        "createdAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    validate_shape(value)
    raw = canonical(value)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as handle:
        handle.write(raw)
        temporary = Path(handle.name)
    os.chmod(temporary, 0o644)
    os.replace(temporary, output)
    return value


def verify(args: argparse.Namespace) -> dict[str, Any]:
    _validate_arguments(args)
    receipt = load(resolved_input(args.receipt, "receipt-missing-or-symlink"))
    validate_shape(receipt)
    archive = resolved_input(args.archive, "archive-missing-or-symlink")
    manifest = resolved_input(args.abi_manifest, "abi-manifest-missing-or-symlink")
    manifest_document, manifest_raw = validate_abi_manifest(
        manifest,
        target=args.target,
        variant=args.variant,
    )
    build = receipt["build"]
    if build != {
        "target": args.target,
        "profile": args.profile,
        "variant": args.variant,
        "rustVersion": "1.97.1",
    }:
        fail("build-binding")
    current_source = source_identity()
    current_build_input = current_build_input_identity(require_clean=args.require_clean)
    receipt_build_input = receipt["artifact"]["abiBinding"]["buildInputSha256"]
    if current_build_input != receipt_build_input:
        fail("build-input-binding")
    artifact = artifact_record(
        archive,
        manifest_document,
        manifest_raw,
        target=args.target,
        profile=args.profile,
        variant=args.variant,
        source=receipt["source"],
        build_input_sha256=receipt_build_input,
    )
    if receipt["artifact"] != artifact:
        fail("artifact-binding")
    if receipt["inputs"] != expected_inputs(manifest):
        fail("input-binding")
    if (
        receipt["source"]["gitSha"] != current_source["gitSha"]
        or receipt["source"]["gitTree"] != current_source["gitTree"]
    ):
        fail("source-head-binding")
    if args.require_clean and current_source["dirty"]:
        fail("source-not-clean")
    return receipt


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("create", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--archive", required=True, type=Path)
        command.add_argument("--abi-manifest", required=True, type=Path)
        command.add_argument("--target", required=True)
        command.add_argument("--profile", required=True, choices=("ffi-release",))
        command.add_argument("--variant", required=True, choices=("full", "minimal"))
        if name == "create":
            command.add_argument("--output", required=True, type=Path)
            command.add_argument("--replace", action="store_true")
        else:
            command.add_argument("--receipt", required=True, type=Path)
            command.add_argument("--require-clean", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        value = create(args) if args.command == "create" else verify(args)
    except (OSError, subprocess.CalledProcessError, ReceiptError) as error:
        print("core-ffi-receipt-invalid:" + str(error), file=sys.stderr)
        return 1
    print(
        "core-ffi-receipt-%s target=%s artifactSha256=%s"
        % (
            "created" if args.command == "create" else "valid",
            value["build"]["target"],
            value["artifact"]["sha256"],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
