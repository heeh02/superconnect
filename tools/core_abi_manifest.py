#!/usr/bin/env python3
"""Generate target- and variant-qualified canonical Core C ABI manifests."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from core_abi_extract import declared_function_symbols, generate_manifest
from core_abi_model import (
    DEFAULT_CONFIG,
    DEFAULT_IDENTITY_HEADER,
    DEFAULT_INCLUDE_DIR,
    DEFAULT_SURFACE_ROOT,
    DEFAULT_SYMBOL_BASELINE,
    CoreAbiManifestError,
    canonical_bytes,
    identity_hex,
    load_config,
    load_json,
    manifest_identity,
    target_config,
)
from core_abi_normalize import (
    abi_surface,
    generate_set,
    identity_header,
    materialize_manifest,
    resolve_manifest,
    write_or_check,
)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate")
    generate.add_argument("--target", required=True)
    generate.add_argument("--variant", choices=("full", "minimal"), required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate_set_parser = subparsers.add_parser("generate-set")
    generate_set_parser.add_argument("--surface-root", type=Path, default=DEFAULT_SURFACE_ROOT)
    generate_set_parser.add_argument("--identity-header", type=Path, default=DEFAULT_IDENTITY_HEADER)
    generate_set_parser.add_argument("--check", action="store_true")
    identity = subparsers.add_parser("identity")
    identity.add_argument("--manifest", type=Path, required=True)
    materialize = subparsers.add_parser("materialize")
    materialize.add_argument("--target", required=True)
    materialize.add_argument("--variant", choices=("full", "minimal"), required=True)
    materialize.add_argument("--output", type=Path, required=True)
    materialize.add_argument("--surface-root", type=Path, default=DEFAULT_SURFACE_ROOT)
    materialize.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    symbols = subparsers.add_parser("symbols")
    symbols.add_argument("--target", required=True)
    symbols.add_argument("--output", type=Path, default=DEFAULT_SYMBOL_BASELINE)
    symbols.add_argument("--check", action="store_true")
    symbols.add_argument("--include-dir", type=Path, default=DEFAULT_INCLUDE_DIR)
    symbols.add_argument("--clang", default="clang")
    for command in (generate, generate_set_parser):
        command.add_argument("--include-dir", type=Path, default=DEFAULT_INCLUDE_DIR)
        command.add_argument("--symbol-baseline", type=Path, default=DEFAULT_SYMBOL_BASELINE)
        command.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
        command.add_argument("--clang", default="clang")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "generate":
            raw = canonical_bytes(
                generate_manifest(
                    target=args.target,
                    variant=args.variant,
                    include_dir=args.include_dir,
                    symbol_baseline=args.symbol_baseline,
                    config_path=args.config,
                    clang=args.clang,
                )
            )
            write_or_check(args.output, raw, False)
            print(identity_hex(raw))
        elif args.command == "generate-set":
            identities = generate_set(
                surface_root=args.surface_root,
                identity_header_path=args.identity_header,
                include_dir=args.include_dir,
                symbol_baseline=args.symbol_baseline,
                config_path=args.config,
                clang=args.clang,
                check=args.check,
            )
            print(f"core_abi_manifest_set_valid manifests={len(identities)}")
        elif args.command == "materialize":
            raw = canonical_bytes(
                materialize_manifest(
                    target=args.target,
                    variant=args.variant,
                    config_path=args.config,
                    surface_root=args.surface_root,
                )
            )
            write_or_check(args.output, raw, False)
            print(identity_hex(raw))
        elif args.command == "symbols":
            names = declared_function_symbols(
                target=args.target,
                include_dir=args.include_dir,
                clang=args.clang,
            )
            write_or_check(
                args.output,
                ("\n".join(names) + "\n").encode("utf-8"),
                args.check,
            )
            print(f"core_abi_symbol_baseline_valid symbols={len(names)}")
        else:
            print(manifest_identity(args.manifest))
    except (CoreAbiManifestError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"core_abi_manifest_invalid: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
