"""Shared constants, identity, hashing, and strict JSON for Core FFI receipts."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any, Iterable, NoReturn


ROOT = Path(__file__).resolve().parents[1]
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
TARGET = re.compile(r"^[a-z0-9_][a-z0-9_.-]*$")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
CONTRACT = {"name": "superconnect.core-ffi-receipt", "version": 1}
MARKER_CONTRACT = {"name": "superconnect.core-abi-archive-marker", "version": 1}
MARKER_PREFIX = b"SC_CORE_ABI_ARCHIVE_MARKER_V1|"
MARKER_LIMIT = 512
AR_MAGIC = b"!<arch>\n"
AR_HEADER_SIZE = 60
RUST_TOOLCHAIN = "1.97.1"
LLVM_TOOLS_VERSION = "22.1.6-rust-1.97.1-stable"
BUILD_INPUT_TOOL = ROOT / "tools/core_ffi_build_inputs.py"

ABI_TOOL_PATHS = (
    ROOT / "tools/core_abi_manifest.py",
    ROOT / "tools/core_abi_model.py",
    ROOT / "tools/core_abi_extract.py",
    ROOT / "tools/core_abi_normalize.py",
)
RECEIPT_TOOL_PATHS = (
    ROOT / "tools/core_ffi_receipt.py",
    ROOT / "tools/core_ffi_receipt_common.py",
    ROOT / "tools/core_ffi_manifest_validator.py",
    ROOT / "tools/core_ffi_archive_validator.py",
)


class ReceiptError(Exception):
    """A stable, user-facing Core FFI receipt validation failure."""


def fail(code: str) -> NoReturn:
    raise ReceiptError(code)


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        fail("input-missing-or-symlink:" + str(path))
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def resolved_input(path: Path, code: str) -> Path:
    if path.is_symlink() or not path.is_file():
        fail(code)
    return path.resolve()


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file_set(paths: Iterable[Path]) -> str:
    value = hashlib.sha256()
    selected = sorted(Path(path) for path in paths)
    if not selected:
        fail("abi-surface-set-empty")
    for path in selected:
        if path.is_symlink() or not path.is_file():
            fail("input-missing-or-symlink:" + str(path))
        try:
            name = path.relative_to(ROOT).as_posix()
        except ValueError:
            fail("input-outside-repository:" + str(path))
        value.update(name.encode("utf-8"))
        value.update(b"\0")
        value.update(bytes.fromhex(digest(path)))
        value.update(b"\0")
    return value.hexdigest()


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def source_identity() -> dict[str, Any]:
    return {
        "gitSha": git("rev-parse", "HEAD"),
        "gitTree": git("rev-parse", "HEAD^{tree}"),
        "dirty": bool(git("status", "--porcelain=v1", "--untracked-files=all")),
    }


def canonical(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as error:
        raise ReceiptError("json-value") from error
    return (encoded + "\n").encode("utf-8")


def _strict_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("json-duplicate-key:" + key)
        result[key] = value
    return result


def parse_json(raw: bytes, *, code: str) -> Any:
    try:
        return json.loads(raw, object_pairs_hook=_strict_object)
    except ReceiptError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReceiptError(code) from error


def load_receipt(path: Path) -> dict[str, Any]:
    path = resolved_input(path, "receipt-missing-or-symlink")
    raw = path.read_bytes()
    value = parse_json(raw, code="receipt-json")
    if not isinstance(value, dict) or raw != canonical(value):
        fail("receipt-not-canonical")
    return value


def nonempty_text(value: Any, code: str) -> str:
    if not isinstance(value, str) or not value:
        fail(code)
    return value


def exact_object(value: Any, fields: set[str], code: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        fail(code)
    return value
