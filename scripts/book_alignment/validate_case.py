#!/usr/bin/env python3
"""Validate a BookAlignmentCase and its local-only binding/profile inputs."""

from __future__ import annotations

import argparse
import pathlib
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import AlignmentError  # type: ignore[import-not-found]
    from book_alignment.contract import load_contract_bundle  # type: ignore[import-not-found]
else:
    from .common import AlignmentError
    from .contract import load_contract_bundle


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate the committed alias-only case plus ignored bindings/profile. "
            "No binding values are printed."
        )
    )
    parser.add_argument("--case", type=pathlib.Path, required=True)
    parser.add_argument("--bindings", type=pathlib.Path, required=True)
    parser.add_argument("--runtime-profile", type=pathlib.Path)
    parser.add_argument(
        "--runnable",
        action="store_true",
        help="also reject pending protocol and missing required runtime profile",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        bundle = load_contract_bundle(
            args.case,
            args.bindings,
            args.runtime_profile,
            runnable=args.runnable,
        )
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"PASS case={bundle.case['caseId']} status={bundle.case['status']} "
        f"aliases={len(bundle.case['aliases'])} "
        f"projections={len(bundle.case['oracle']['semanticProjections'])}; "
        "private binding values omitted"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
