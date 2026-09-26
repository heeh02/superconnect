"""Validate Core FFI archive marker, symbols, and target architecture."""

from __future__ import annotations

import collections
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from core_ffi_manifest_validator import run_checked
from core_ffi_receipt_common import (
    AR_HEADER_SIZE,
    AR_MAGIC,
    LLVM_TOOLS_VERSION,
    MARKER_LIMIT,
    MARKER_PREFIX,
    ROOT,
    RUST_TOOLCHAIN,
    SHA1,
    SHA256,
    TARGET,
    ReceiptError,
    digest_bytes,
    fail,
)


def marker_bytes(
    *,
    manifest_sha256: str,
    target: str,
    variant: str,
    profile: str,
    git_sha: str,
    git_tree: str,
    build_input_sha256: str,
    clean: bool,
) -> bytes:
    if (
        not SHA256.fullmatch(manifest_sha256)
        or not TARGET.fullmatch(target)
        or variant not in {"full", "minimal"}
        or profile != "ffi-release"
        or not SHA1.fullmatch(git_sha)
        or not SHA1.fullmatch(git_tree)
        or not SHA256.fullmatch(build_input_sha256)
        or clean is not True
    ):
        fail("abi-marker-input")
    return (
        "SC_CORE_ABI_ARCHIVE_MARKER_V1|"
        f"sha256={manifest_sha256}|target={target}|variant={variant}|profile={profile}|"
        f"git={git_sha}|tree={git_tree}|inputs={build_input_sha256}|clean=1|END\0"
    ).encode("ascii")


def _is_object(payload: bytes) -> bool:
    if payload.startswith(b"\x7fELF") or payload.startswith(b"BC\xc0\xde"):
        return True
    if payload[:4] in {
        b"\xfe\xed\xfa\xce",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xcf\xfa\xed\xfe",
    }:
        return True
    # COFF machine values: i386, AMD64, ARM and ARM64.
    return payload[:2] in {b"\x4c\x01", b"\x64\x86", b"\xc0\x01", b"\x64\xaa"}


def archive_members(raw: bytes) -> list[tuple[str, bytes, bytes]]:
    if not raw.startswith(AR_MAGIC):
        fail("archive-format-magic")
    offset = len(AR_MAGIC)
    members: list[tuple[str, bytes, bytes]] = []
    while offset < len(raw):
        if len(raw) - offset < AR_HEADER_SIZE:
            fail("archive-trailing-bytes")
        header = raw[offset : offset + AR_HEADER_SIZE]
        if header[58:60] != b"`\n":
            fail("archive-member-header")
        try:
            name_field = header[:16].decode("ascii").rstrip()
            size_field = header[48:58].decode("ascii").strip()
        except UnicodeError as error:
            raise ReceiptError("archive-member-header-ascii") from error
        if not size_field.isdigit():
            fail("archive-member-size")
        size = int(size_field, 10)
        data_start = offset + AR_HEADER_SIZE
        data_end = data_start + size
        if data_end > len(raw):
            fail("archive-member-truncated")
        stored = raw[data_start:data_end]
        payload = stored
        name = name_field.rstrip("/")
        if name_field.startswith("#1/"):
            length_text = name_field[3:]
            if not length_text.isdigit():
                fail("archive-bsd-name-length")
            name_length = int(length_text, 10)
            if name_length <= 0 or name_length > len(stored):
                fail("archive-bsd-name-truncated")
            try:
                name = stored[:name_length].rstrip(b"\0").decode("utf-8")
            except UnicodeError as error:
                raise ReceiptError("archive-bsd-name") from error
            payload = stored[name_length:]
        members.append((name, payload, stored))
        offset = data_end
        if size % 2:
            if offset >= len(raw) or raw[offset : offset + 1] != b"\n":
                fail("archive-member-padding")
            offset += 1
    if offset != len(raw) or not members:
        fail("archive-trailing-bytes")
    return members


def verify_archive_marker(archive: Path, expected: bytes) -> None:
    if archive.is_symlink() or not archive.is_file():
        fail("archive-missing-or-symlink")
    raw = archive.read_bytes()
    occurrences: list[tuple[str, bytes, int, bool]] = []
    for name, payload, stored in archive_members(raw):
        position = 0
        while True:
            found = stored.find(MARKER_PREFIX, position)
            if found < 0:
                break
            payload_start = len(stored) - len(payload)
            in_object_payload = _is_object(payload) and found >= payload_start
            occurrences.append((name, stored, found, in_object_payload))
            position = found + 1
    if not occurrences:
        fail("abi-marker-missing")
    if len(occurrences) != 1:
        fail("abi-marker-duplicate")
    name, stored, start, in_object_payload = occurrences[0]
    if not in_object_payload:
        fail("abi-marker-not-object-member:" + name)
    end = stored.find(b"\0", start)
    if end < 0 or end + 1 - start > MARKER_LIMIT:
        fail("abi-marker-malformed")
    actual = stored[start : end + 1]
    if actual != expected:
        fail("abi-marker-binding")


def llvm_nm_executable_name(platform_name: str = os.name) -> str:
    return "llvm-nm.exe" if platform_name == "nt" else "llvm-nm"


def windows_git_bash_candidates(git_executable: Path) -> tuple[Path, ...]:
    git_root = next(
        (
            parent
            for parent in (git_executable.parent, *git_executable.parents)
            if parent.name.lower() == "git"
        ),
        None,
    )
    if git_root is None:
        return ()
    return (git_root / "bin/bash.exe", git_root / "usr/bin/bash.exe")


def resolve_bash() -> Path:
    candidates: tuple[Path, ...]
    if os.name == "nt":
        git = shutil.which("git.exe") or shutil.which("git")
        if not git:
            fail("archive-architecture-git-bash-missing")
        candidates = windows_git_bash_candidates(Path(git).resolve())
    else:
        bash = shutil.which("bash")
        candidates = (Path(bash).resolve(),) if bash else ()
    for candidate in candidates:
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        result = subprocess.run(
            [str(candidate), "--version"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and "GNU bash" in result.stdout:
            return candidate
    fail("archive-architecture-gnu-bash-missing")


def resolve_nm() -> Path:
    # Only llvm-nm from the exact Rust toolchain is accepted; there is no formal override.
    try:
        rustc = Path(
            subprocess.check_output(
                ["rustup", "which", "--toolchain", RUST_TOOLCHAIN, "rustc"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReceiptError("archive-symbol-toolchain-missing") from error
    sysroot = run_checked([str(rustc), "--print", "sysroot"], "archive-symbol-sysroot").strip()
    verbose = run_checked([str(rustc), "-vV"], "archive-symbol-rustc-version")
    host_lines = [
        line.removeprefix("host: ")
        for line in verbose.splitlines()
        if line.startswith("host: ")
    ]
    if len(host_lines) != 1 or not TARGET.fullmatch(host_lines[0]):
        fail("archive-symbol-rust-host")
    candidate = (
        Path(sysroot)
        / "lib/rustlib"
        / host_lines[0]
        / "bin"
        / llvm_nm_executable_name()
    )
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        fail("archive-symbol-tool-missing:llvm-tools-preview")
    version = run_checked([str(candidate), "--version"], "archive-symbol-tool-version")
    if f"LLVM version {LLVM_TOOLS_VERSION}" not in version:
        fail("archive-symbol-tool-version-binding")
    return candidate


def verify_archive_symbols(
    archive: Path,
    manifest: dict[str, Any],
) -> tuple[int, str]:
    nm = resolve_nm()
    output = run_checked(
        [str(nm), "-g", "--defined-only", str(archive)],
        "archive-symbol-scan",
    )
    observed: list[str] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        candidate = line.split()[-1]
        if candidate.startswith("_sc_"):
            candidate = candidate[1:]
        if re.fullmatch(r"sc_[A-Za-z0-9_]+", candidate):
            observed.append(candidate)
    counts = collections.Counter(observed)
    duplicates = sorted(name for name, count in counts.items() if count != 1)
    if duplicates:
        fail("archive-symbol-duplicate:" + ",".join(duplicates))
    expected = [symbol["name"] for symbol in manifest["symbols"]]
    actual = sorted(counts)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        fail(
            "archive-symbol-binding:missing=%s:extra=%s"
            % (",".join(missing), ",".join(extra))
        )
    raw = ("\n".join(actual) + "\n").encode("ascii")
    return len(actual), digest_bytes(raw)


def verify_archive_architecture(
    archive: Path,
    *,
    target: str,
    profile: str,
    variant: str,
) -> None:
    run_checked(
        [
            str(resolve_bash()),
            str(ROOT / "tools/build-core-ffi.sh"),
            "--verify-archive",
            str(archive),
            "--target",
            target,
            "--profile",
            profile,
            "--variant",
            variant,
        ],
        "archive-architecture",
    )
