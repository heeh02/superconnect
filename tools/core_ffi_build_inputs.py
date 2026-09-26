#!/usr/bin/env python3
"""Compute the content identity of the canonical Rust Core FFI build inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable, NoReturn, Sequence


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1
DEFAULT_SELECTION = (
    ".gitattributes",
    ".cargo",
    "core",
    "qa/baselines/product-symbols/core-abi.txt",
    "release/TOOLCHAINS.lock.json",
    "rust-toolchain.toml",
    "tools/build-core-ffi.sh",
    "tools/core_abi_extract.py",
    "tools/core_abi_manifest.py",
    "tools/core_abi_model.py",
    "tools/core_abi_normalize.py",
    "tools/core_ffi_archive_validator.py",
    "tools/core_ffi_build_inputs.py",
    "tools/core_ffi_manifest_validator.py",
    "tools/core_ffi_receipt.py",
    "tools/core_ffi_receipt_common.py",
    "tools/lib/rust-toolchain.sh",
)
REQUIRED_PATHS = {
    ".gitattributes",
    "core/Cargo.lock",
    "core/Cargo.toml",
    "core/build.rs",
    "core/abi/manifest-config-v1.json",
    "core/include/superconnect_core.h",
    "core/include/superconnect_core_abi_identity_v1.h",
    "qa/baselines/product-symbols/core-abi.txt",
    "release/TOOLCHAINS.lock.json",
    "rust-toolchain.toml",
    "tools/build-core-ffi.sh",
    "tools/core_abi_extract.py",
    "tools/core_abi_manifest.py",
    "tools/core_abi_model.py",
    "tools/core_abi_normalize.py",
    "tools/core_ffi_archive_validator.py",
    "tools/core_ffi_build_inputs.py",
    "tools/core_ffi_manifest_validator.py",
    "tools/core_ffi_receipt.py",
    "tools/core_ffi_receipt_common.py",
    "tools/lib/rust-toolchain.sh",
}
SHA1_LENGTH = 40


class BuildInputError(Exception):
    pass


def fail(code: str) -> NoReturn:
    raise BuildInputError(code)


def canonical(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, allow_nan=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _run(
    root: Path,
    arguments: Sequence[str],
    *,
    code: str,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise BuildInputError(code + ":git-unavailable") from error
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        fail(code + (":" + detail.replace("\n", " | ") if detail else ""))
    return result


def _git_text(root: Path, arguments: Sequence[str], *, code: str) -> str:
    try:
        return _run(root, arguments, code=code).stdout.decode("utf-8").strip()
    except UnicodeError as error:
        raise BuildInputError(code + ":non-utf8") from error


def _decode_paths(raw: bytes, code: str) -> list[str]:
    values = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        try:
            path = item.decode("utf-8")
        except UnicodeError as error:
            raise BuildInputError(code + ":non-utf8") from error
        if path.startswith("/") or path in {".", ".."} or "/../" in "/" + path + "/":
            fail(code + ":unsafe-path")
        values.append(path)
    return values


def require_clean_repository(root: Path) -> None:
    status = _run(
        root,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no"],
        code="source-status",
    ).stdout
    if status:
        fail("source-not-clean")
    if _run(root, ["diff", "--quiet", "HEAD", "--"], code="source-worktree-diff", check=False).returncode != 0:
        fail("source-worktree-diff")
    if _run(root, ["diff", "--cached", "--quiet", "HEAD", "--"], code="source-index-diff", check=False).returncode != 0:
        fail("source-index-drift")
    if _run(root, ["ls-files", "-u", "-z"], code="source-unmerged").stdout:
        fail("source-index-unmerged")
    flags = _decode_paths(_run(root, ["ls-files", "-v", "-z"], code="source-index-flags").stdout, "source-index-flags")
    # `git ls-files -v` prefixes every path with one tag and a space. Lower-case tags mean
    # assume-unchanged; `S` means skip-worktree. Both can hide worktree changes from status.
    hidden = []
    for record in flags:
        if len(record) < 3 or record[1] != " ":
            fail("source-index-flag-shape")
        tag = record[0]
        if tag == "S" or tag.islower():
            hidden.append(record[2:])
    if hidden:
        fail("source-index-hidden-paths:" + ",".join(sorted(hidden)))


def _tracked_paths(root: Path, selection: Sequence[str], required: set[str]) -> list[str]:
    raw = _run(
        root,
        ["ls-files", "-z", "--", *selection],
        code="build-input-list",
    ).stdout
    paths = sorted(_decode_paths(raw, "build-input-list"))
    if not paths or len(paths) != len(set(paths)):
        fail("build-input-list-empty-or-duplicate")
    missing = sorted(required - set(paths))
    if missing:
        fail("build-input-required-untracked:" + ",".join(missing))
    return paths


def _index_entries(root: Path, selection: Sequence[str]) -> dict[str, tuple[str, str]]:
    raw = _run(
        root,
        ["ls-files", "-s", "-z", "--", *selection],
        code="build-input-index",
    ).stdout
    result: dict[str, tuple[str, str]] = {}
    for record in _decode_paths(raw, "build-input-index"):
        try:
            metadata, path = record.split("\t", 1)
            mode, blob, stage = metadata.split(" ")
        except ValueError as error:
            raise BuildInputError("build-input-index-shape") from error
        if stage != "0" or path in result or len(blob) != SHA1_LENGTH:
            fail("build-input-index-shape")
        result[path] = (mode, blob)
    return result


def _head_entries(root: Path, selection: Sequence[str]) -> dict[str, tuple[str, str]]:
    raw = _run(
        root,
        ["ls-tree", "-r", "-z", "HEAD", "--", *selection],
        code="build-input-head",
    ).stdout
    result: dict[str, tuple[str, str]] = {}
    for record in _decode_paths(raw, "build-input-head"):
        try:
            metadata, path = record.split("\t", 1)
            mode, object_type, blob = metadata.split(" ")
        except ValueError as error:
            raise BuildInputError("build-input-head-shape") from error
        if object_type != "blob" or path in result or len(blob) != SHA1_LENGTH:
            fail("build-input-head-shape")
        result[path] = (mode, blob)
    return result


def _reject_content_transform_attributes(root: Path, paths: Sequence[str]) -> None:
    attributes = ("filter", "working-tree-encoding", "ident", "export-subst", "export-ignore")
    raw = _run(
        root,
        ["check-attr", "-z", *attributes, "--", *paths],
        code="build-input-attributes",
    ).stdout
    values = raw.split(b"\0")
    if values and values[-1] == b"":
        values.pop()
    if len(values) != len(paths) * len(attributes) * 3 or len(values) % 3:
        fail("build-input-attribute-shape")
    for index in range(0, len(values), 3):
        try:
            path, attribute, value = (item.decode("utf-8") for item in values[index:index + 3])
        except UnicodeError as error:
            raise BuildInputError("build-input-attribute-non-utf8") from error
        if path not in paths:
            fail("build-input-attribute-path")
        if attribute in {"filter", "working-tree-encoding"} and value != "unspecified":
            fail(f"build-input-transform-attribute:{path}:{attribute}={value}")
        if attribute == "ident" and value not in {"unspecified", "unset"}:
            fail(f"build-input-transform-attribute:{path}:{attribute}={value}")
        if attribute in {"export-subst", "export-ignore"} and value not in {"unspecified", "unset"}:
            fail(f"build-input-transform-attribute:{path}:{attribute}={value}")


def build_input_document(
    root: Path = ROOT,
    *,
    require_clean: bool,
    selection: Sequence[str] = DEFAULT_SELECTION,
    required: set[str] = REQUIRED_PATHS,
) -> dict[str, Any]:
    root = root.resolve()
    if require_clean:
        require_clean_repository(root)
    git_sha = _git_text(root, ["rev-parse", "HEAD"], code="source-head")
    git_tree = _git_text(root, ["rev-parse", "HEAD^{tree}"], code="source-tree")
    if len(git_sha) != SHA1_LENGTH or len(git_tree) != SHA1_LENGTH:
        fail("source-identity-shape")
    paths = _tracked_paths(root, selection, required)
    _reject_content_transform_attributes(root, paths)
    index = _index_entries(root, selection)
    head = _head_entries(root, selection)
    if set(index) != set(paths) or set(head) != set(paths):
        fail("build-input-index-head-set")
    entries = []
    for relative in paths:
        mode, index_blob = index[relative]
        if head[relative] != (mode, index_blob):
            fail("build-input-index-head-drift:" + relative)
        path = root / relative
        if path.is_symlink() or not path.is_file():
            fail("build-input-missing-or-symlink:" + relative)
        raw = path.read_bytes()
        filtered_blob = _git_text(
            root,
            ["hash-object", f"--path={relative}", "--", relative],
            code="build-input-hash:" + relative,
        )
        if filtered_blob != index_blob:
            fail("build-input-worktree-index-drift:" + relative)
        entries.append(
            {
                "gitBlobSha1": filtered_blob,
                "mode": mode,
                "path": relative,
                "rawSha256": hashlib.sha256(raw).hexdigest(),
                "size": len(raw),
            }
        )
    return {
        "entries": entries,
        "schemaVersion": SCHEMA_VERSION,
        "selection": list(selection),
        "source": {"gitSha": git_sha, "gitTree": git_tree},
    }


def build_input_identity(*args: Any, **kwargs: Any) -> str:
    return hashlib.sha256(canonical(build_input_document(*args, **kwargs))).hexdigest()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", choices=("identity", "selection"))
    result.add_argument("--require-clean", action="store_true")
    result.add_argument("--json", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "selection":
        if args.require_clean or args.json:
            print(
                "core-ffi-build-input-invalid:selection-does-not-accept-identity-options",
                file=sys.stderr,
            )
            return 2
        print("\n".join(DEFAULT_SELECTION))
        return 0
    try:
        document = build_input_document(require_clean=args.require_clean)
    except (BuildInputError, OSError, ValueError) as error:
        print("core-ffi-build-input-invalid:" + str(error), file=sys.stderr)
        return 1
    raw = canonical(document)
    if args.json:
        sys.stdout.buffer.write(raw)
    else:
        print(hashlib.sha256(raw).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
