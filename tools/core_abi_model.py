"""Shared model, canonicalization, and configuration rules for Core ABI tooling."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable, NoReturn


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INCLUDE_DIR = ROOT / "core/include"
DEFAULT_SYMBOL_BASELINE = ROOT / "qa/baselines/product-symbols/core-abi.txt"
DEFAULT_CONFIG = ROOT / "core/abi/manifest-config-v1.json"
DEFAULT_SURFACE_ROOT = ROOT / "core/abi/surfaces-v1"
DEFAULT_IDENTITY_HEADER = ROOT / "core/include/superconnect_core_abi_identity_v1.h"
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class CoreAbiManifestError(Exception):
    """A stable, user-facing Core ABI manifest validation failure."""


def fail(message: str) -> NoReturn:
    raise CoreAbiManifestError(message)


def _strict_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            Path(path).read_text(encoding="utf-8"),
            object_pairs_hook=_strict_object,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")


def canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def identity_hex(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()[:16]


def manifest_identity(path: Path) -> str:
    raw = Path(path).read_bytes()
    document = json.loads(raw, object_pairs_hook=_strict_object)
    if raw != canonical_bytes(document):
        fail(f"manifest is not canonical JSON: {path}")
    return identity_hex(raw)


def _validate_config(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "targets",
        "variants",
    }:
        fail("manifest config has unexpected fields")
    if document["schemaVersion"] != 1:
        fail("manifest config schemaVersion must be 1")
    targets = document["targets"]
    variants = document["variants"]
    if not isinstance(targets, list) or not targets:
        fail("manifest config targets must be a non-empty array")
    if not isinstance(variants, dict) or set(variants) != {"full", "minimal"}:
        fail("manifest config variants must be exactly full and minimal")
    seen: set[str] = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {
            "triple",
            "clangTarget",
            "preprocessorCondition",
            "surface",
        }:
            fail("manifest target has unexpected fields")
        triple = target["triple"]
        if not isinstance(triple, str) or not triple or triple in seen:
            fail(f"invalid or duplicate manifest target: {triple!r}")
        seen.add(triple)
        for field in ("clangTarget", "preprocessorCondition", "surface"):
            if not isinstance(target[field], str) or not target[field]:
                fail(f"manifest target {triple} lacks {field}")
    for name, variant in variants.items():
        if not isinstance(variant, dict) or set(variant) != {"excludedSymbols"}:
            fail(f"variant {name} has unexpected fields")
        excluded = variant["excludedSymbols"]
        if (
            not isinstance(excluded, list)
            or any(
                not isinstance(symbol, str) or not IDENTIFIER_RE.fullmatch(symbol)
                for symbol in excluded
            )
            or len(set(excluded)) != len(excluded)
        ):
            fail(f"variant {name} has invalid excludedSymbols")
    return document


def load_config(path: Path = DEFAULT_CONFIG) -> dict[str, Any]:
    return _validate_config(load_json(path))


def target_config(config: dict[str, Any], triple: str) -> dict[str, str]:
    for target in config["targets"]:
        if target["triple"] == triple:
            return target
    fail(f"unsupported Core ABI target: {triple}")
