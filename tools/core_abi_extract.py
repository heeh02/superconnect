"""Extract complete Core C ABI declarations and layouts with Clang."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterable, Sequence

from core_abi_model import (
    DEFAULT_CONFIG,
    DEFAULT_INCLUDE_DIR,
    DEFAULT_SYMBOL_BASELINE,
    IDENTIFIER_RE,
    fail,
    load_config,
    target_config,
)


LAYOUT_BLOCK_RE = re.compile(
    r"\*\*\* Dumping AST Record Layout\s+"
    r"Type: struct (?P<name>Sc[A-Za-z0-9_]+)\s+"
    r"Layout: <ASTRecordLayout\s+"
    r"(?P<body>.*?)>",
    re.DOTALL,
)
SIZE_RE = re.compile(r"^\s*Size:(\d+)\s*$", re.MULTILINE)
ALIGN_RE = re.compile(r"^\s*Alignment:(\d+)\s*$", re.MULTILINE)
OFFSETS_RE = re.compile(r"^\s*FieldOffsets: \[([^\]]*)\]\s*$", re.MULTILINE)


def _run(command: Sequence[str], *, code: str) -> str:
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        fail(f"{code}: {error}")
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"status {result.returncode}"
        fail(f"{code}: {detail}")
    return result.stdout


def _probe_source(directory: Path) -> Path:
    source = directory / "core_abi_manifest_probe.c"
    source.write_text('#include "superconnect_core.h"\n', encoding="utf-8")
    return source


def _clang_ast(
    clang: str,
    clang_target: str,
    include_dir: Path,
    source: Path,
) -> dict[str, Any]:
    output = _run(
        [
            clang,
            "-target",
            clang_target,
            "-ffreestanding",
            "-std=c11",
            "-I",
            str(include_dir),
            "-Xclang",
            "-ast-dump=json",
            "-fsyntax-only",
            str(source),
        ],
        code=f"clang AST failed for {clang_target}",
    )
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        fail(f"clang AST was not JSON for {clang_target}: {error}")
    if not isinstance(value, dict):
        fail(f"clang AST root is invalid for {clang_target}")
    return value


def _clang_layouts(
    clang: str,
    clang_target: str,
    include_dir: Path,
    source: Path,
) -> dict[str, dict[str, Any]]:
    output = _run(
        [
            clang,
            "-target",
            clang_target,
            "-ffreestanding",
            "-std=c11",
            "-I",
            str(include_dir),
            "-Xclang",
            "-fdump-record-layouts-simple",
            "-Xclang",
            "-fdump-record-layouts-complete",
            "-fsyntax-only",
            str(source),
        ],
        code=f"clang layout probe failed for {clang_target}",
    )
    layouts: dict[str, dict[str, Any]] = {}
    for match in LAYOUT_BLOCK_RE.finditer(output):
        name = match.group("name")
        body = match.group("body")
        size_match = SIZE_RE.search(body)
        align_match = ALIGN_RE.search(body)
        offsets_match = OFFSETS_RE.search(body)
        if size_match is None or align_match is None or offsets_match is None:
            fail(f"incomplete Clang record layout for {name} on {clang_target}")
        size_bits = int(size_match.group(1))
        alignment_bits = int(align_match.group(1))
        raw_offsets = offsets_match.group(1).strip()
        offsets_bits = (
            []
            if not raw_offsets
            else [int(value.strip()) for value in raw_offsets.split(",")]
        )
        if size_bits % 8 or alignment_bits % 8 or any(value % 8 for value in offsets_bits):
            fail(f"non-byte record layout for {name} on {clang_target}")
        if name in layouts:
            fail(f"duplicate Clang record layout for {name} on {clang_target}")
        layouts[name] = {
            "sizeBytes": size_bits // 8,
            "alignmentBytes": alignment_bits // 8,
            "offsetsBytes": [value // 8 for value in offsets_bits],
        }
    return layouts


def _children(node: dict[str, Any], kind: str) -> list[dict[str, Any]]:
    return [child for child in node.get("inner", []) if child.get("kind") == kind]


def _walk(node: dict[str, Any]) -> Iterable[dict[str, Any]]:
    yield node
    for child in node.get("inner", []):
        yield from _walk(child)


def _type_record(node: dict[str, Any]) -> dict[str, str]:
    value = node.get("type", {})
    spelled = value.get("qualType")
    if not isinstance(spelled, str) or not spelled:
        fail(f"AST declaration lacks a type: {node.get('kind')} {node.get('name')}")
    canonical = value.get("desugaredQualType", spelled)
    if not isinstance(canonical, str) or not canonical:
        fail(f"AST declaration lacks a canonical type: {node.get('name')}")
    return {"spelled": spelled, "canonical": canonical}


def _enum_value(node: dict[str, Any], previous: int | None) -> int:
    for candidate in _walk(node):
        raw = candidate.get("value")
        if candidate.get("kind") == "ConstantExpr" and isinstance(raw, str):
            try:
                return int(raw, 0)
            except ValueError:
                fail(f"non-integral enum value for {node.get('name')}: {raw}")
    return 0 if previous is None else previous + 1


def _load_symbols(path: Path) -> list[str]:
    try:
        symbols = [line.strip() for line in Path(path).read_text(encoding="utf-8").splitlines()]
    except (OSError, UnicodeError) as error:
        fail(f"cannot read symbol baseline {path}: {error}")
    if (
        not symbols
        or any(not IDENTIFIER_RE.fullmatch(symbol) for symbol in symbols)
        or symbols != sorted(symbols)
        or len(symbols) != len(set(symbols))
    ):
        fail("Core ABI symbol baseline must be non-empty, sorted and unique")
    return symbols


def declared_function_symbols(
    *, target: str, include_dir: Path, clang: str = "clang"
) -> list[str]:
    """Return the sorted public sc_* declarations from the umbrella header."""
    with tempfile.TemporaryDirectory(prefix="superconnect-core-abi-symbols-") as temporary:
        source = _probe_source(Path(temporary))
        ast = _clang_ast(clang, target, include_dir, source)
    symbols = [
        node["name"]
        for node in _walk(ast)
        if node.get("kind") == "FunctionDecl"
        and isinstance(node.get("name"), str)
        and node["name"].startswith("sc_")
    ]
    if len(symbols) != len(set(symbols)):
        fail("duplicate public function declaration in umbrella header")
    return sorted(symbols)


def _symbol_manifest(
    ast: dict[str, Any],
    selected_symbols: list[str],
    full_symbols: list[str],
) -> list[dict[str, Any]]:
    declarations: dict[str, dict[str, Any]] = {}
    for node in _walk(ast):
        name = node.get("name")
        if node.get("kind") == "FunctionDecl" and isinstance(name, str) and name.startswith("sc_"):
            if name in declarations:
                fail(f"duplicate public function declaration in umbrella header: {name}")
            declarations[name] = node
    declared = set(declarations)
    expected = set(full_symbols)
    if declared != expected:
        missing = sorted(expected - declared)
        extra = sorted(declared - expected)
        fail(
            "public function declarations differ from symbol baseline: "
            f"missing={missing} extra={extra}"
        )
    result = []
    for name in selected_symbols:
        node = declarations[name]
        if node.get("storageClass") == "static":
            fail(f"exported Core ABI declaration has internal linkage: {name}")
        signature = _type_record(node)["spelled"]
        marker = signature.find(" (")
        if marker < 1:
            fail(f"cannot split public function signature: {name}: {signature}")
        convention_match = re.search(
            r"__attribute__\(\((cdecl|stdcall|fastcall|vectorcall|ms_abi|sysv_abi)\)\)",
            signature,
        )
        calling_convention = (
            convention_match.group(1)
            if convention_match is not None
            else "C/default-for-target"
        )
        visibility = "default"
        for attribute in node.get("inner", []):
            kind = attribute.get("kind")
            if kind == "VisibilityAttr":
                visibility = attribute.get("visibility", "unknown")
            elif kind == "DLLExportAttr":
                visibility = "dllexport"
            elif kind == "DLLImportAttr":
                visibility = "dllimport"
        result.append(
            {
                "callingConvention": calling_convention,
                "linkage": "external",
                "name": name,
                "parameters": [
                    _type_record(parameter) for parameter in _children(node, "ParmVarDecl")
                ],
                "returnType": signature[:marker],
                "signature": signature,
                "visibility": visibility,
            }
        )
    return result


def _enum_manifest(ast: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    names: set[str] = set()
    for node in _walk(ast):
        if node.get("kind") != "EnumDecl":
            continue
        constants = [
            child
            for child in _children(node, "EnumConstantDecl")
            if isinstance(child.get("name"), str) and child["name"].startswith("SC_")
        ]
        if not constants:
            continue
        values = []
        previous: int | None = None
        for constant in constants:
            previous = _enum_value(constant, previous)
            name = constant["name"]
            if name in names:
                fail(f"duplicate public enum constant: {name}")
            names.add(name)
            values.append({"name": name, "value": previous})
        result.append(
            {
                "name": "anonymous:" + values[0]["name"],
                "underlyingType": _type_record(constants[0])["canonical"],
                "values": values,
            }
        )
    return sorted(result, key=lambda value: value["name"])


def _struct_manifest(
    ast: dict[str, Any],
    layouts: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    for node in _walk(ast):
        name = node.get("name")
        fields = _children(node, "FieldDecl")
        if (
            node.get("kind") == "RecordDecl"
            and node.get("tagUsed") == "struct"
            and isinstance(name, str)
            and name.startswith("Sc")
            and fields
        ):
            if name in records:
                fail(f"duplicate complete public struct declaration: {name}")
            records[name] = node
    missing_layouts = sorted(set(records) - set(layouts))
    if missing_layouts:
        fail(f"Clang did not report public struct layouts: {missing_layouts}")
    result = []
    for name in sorted(records):
        fields = _children(records[name], "FieldDecl")
        layout = layouts[name]
        offsets = layout["offsetsBytes"]
        if len(fields) != len(offsets):
            fail(f"field/layout count differs for {name}")
        field_manifest = []
        for field, offset in zip(fields, offsets):
            field_name = field.get("name")
            if not isinstance(field_name, str) or not field_name:
                fail(f"anonymous public field is unsupported in {name}")
            field_manifest.append(
                {"name": field_name, "offsetBytes": offset, "type": _type_record(field)}
            )
        result.append(
            {
                "alignmentBytes": layout["alignmentBytes"],
                "fields": field_manifest,
                "name": name,
                "sizeBytes": layout["sizeBytes"],
            }
        )
    return result


def _typedef_manifest(ast: dict[str, Any]) -> list[dict[str, Any]]:
    declarations: dict[str, dict[str, str]] = {}
    for node in _walk(ast):
        name = node.get("name")
        if node.get("kind") == "TypedefDecl" and isinstance(name, str) and name.startswith("Sc"):
            value = _type_record(node)
            previous = declarations.get(name)
            if previous is not None and previous != value:
                fail(f"conflicting public typedef declarations: {name}")
            declarations[name] = value
    return [{"name": name, "type": declarations[name]} for name in sorted(declarations)]


def generate_manifest(
    *,
    target: str,
    variant: str,
    include_dir: Path = DEFAULT_INCLUDE_DIR,
    symbol_baseline: Path = DEFAULT_SYMBOL_BASELINE,
    config_path: Path = DEFAULT_CONFIG,
    clang: str = "clang",
) -> dict[str, Any]:
    config = load_config(config_path)
    target_entry = target_config(config, target)
    if variant not in config["variants"]:
        fail(f"unsupported Core ABI variant: {variant}")
    if shutil.which(clang) is None and not Path(clang).is_file():
        fail(f"clang is not available: {clang}")
    full_symbols = _load_symbols(symbol_baseline)
    excluded = set(config["variants"][variant]["excludedSymbols"])
    if not excluded <= set(full_symbols):
        fail(f"variant {variant} excludes symbols absent from the full baseline")
    selected_symbols = [symbol for symbol in full_symbols if symbol not in excluded]
    with tempfile.TemporaryDirectory(prefix="sc-core-abi-manifest-") as temporary:
        source = _probe_source(Path(temporary))
        ast = _clang_ast(clang, target_entry["clangTarget"], Path(include_dir), source)
        layouts = _clang_layouts(
            clang,
            target_entry["clangTarget"],
            Path(include_dir),
            source,
        )
    return {
        "enums": _enum_manifest(ast),
        "schemaVersion": 1,
        "structs": _struct_manifest(ast, layouts),
        "symbols": _symbol_manifest(ast, selected_symbols, full_symbols),
        "target": target,
        "typedefs": _typedef_manifest(ast),
        "variant": variant,
    }
