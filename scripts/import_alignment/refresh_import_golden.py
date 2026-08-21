#!/usr/bin/env python3
"""Create or refresh the v2 corpus exclusively from Android Oracle output."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ANDROID_ROOT = Path("/Users/wangke/Workspace/AndroidProjects/XMNote")
FIXTURE_PARENT = REPOSITORY_ROOT / "xmnoteTests/Fixtures/ImportParity"
SOURCE_CORPUS = FIXTURE_PARENT / "v1"
TARGET_CORPUS = FIXTURE_PARENT / "v2"
SOURCE_CLOSURE = REPOSITORY_ROOT / "scripts/import_alignment/android-source-closure.json"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--oracle-output", required=True, type=Path)
    parser.add_argument("--android-root", type=Path, default=DEFAULT_ANDROID_ROOT)
    parser.add_argument("--refresh-existing", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: dict) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def refresh_manifest(
    manifest_path: Path,
    corpus_root: Path,
    oracle_root: Path,
    android_root: Path,
    android_commit: str,
    is_mutation: bool,
) -> None:
    manifest = load_json(manifest_path)
    manifest["schemaVersion"] = 2
    manifest["corpusVersion"] = 2 if is_mutation else 9
    manifest["androidCommit"] = android_commit
    case_root = corpus_root / "mutations" if is_mutation else corpus_root
    oracle_case_root = oracle_root / "mutations" if is_mutation else oracle_root
    for item in manifest["cases"]:
        source = oracle_case_root / item["expected"]
        destination = case_root / item["expected"]
        if not source.is_file():
            raise RuntimeError(f"Android Oracle 缺少输出: {source}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        item["inputSHA256"] = sha256(case_root / item["input"])
        item["expectedSHA256"] = sha256(destination)

    if not is_mutation:
        for source in manifest["parserSources"].values():
            source["sha256"] = sha256(android_root / source["file"])
        manifest["sourceClosure"] = {
            "baseline": "scripts/import_alignment/android-source-closure.json",
            "sha256": sha256(SOURCE_CLOSURE),
        }
    write_json(manifest_path, manifest)


def main() -> int:
    options = arguments()
    oracle_output = options.oracle_output.resolve()
    android_root = options.android_root.resolve()
    closure = load_json(SOURCE_CLOSURE)
    android_commit = closure["androidCommit"]
    if TARGET_CORPUS.exists() and not options.refresh_existing:
        raise RuntimeError(
            f"目标 corpus 已存在: {TARGET_CORPUS}; 明确刷新时传 --refresh-existing"
        )
    if not TARGET_CORPUS.exists():
        shutil.copytree(SOURCE_CORPUS, TARGET_CORPUS)

    refresh_manifest(
        TARGET_CORPUS / "manifest.json",
        TARGET_CORPUS,
        oracle_output,
        android_root,
        android_commit,
        is_mutation=False,
    )
    refresh_manifest(
        TARGET_CORPUS / "mutations/mutation-manifest.json",
        TARGET_CORPUS,
        oracle_output,
        android_root,
        android_commit,
        is_mutation=True,
    )

    rules_path = TARGET_CORPUS / "rules.json"
    rules = load_json(rules_path)
    rules["schemaVersion"] = 2
    rules["corpusVersion"] = 9
    for rule in rules["rules"]:
        if rule["id"] == "dimo-unavailable-attachments":
            rule["id"] = "dimo-stable-attachment-identity"
            rule["behavior"] = (
                "Oracle 固定附件传输成功，验证生产 Parser 保留附件顺序、稳定 URL 与 SHA-256 digest；失败跳过语义由专项测试覆盖"
            )
    write_json(rules_path, rules)
    print(
        f"Android Oracle -> v2 corpus: {len(load_json(TARGET_CORPUS / 'manifest.json')['cases'])} main, "
        f"{len(load_json(TARGET_CORPUS / 'mutations/mutation-manifest.json')['cases'])} mutations, "
        f"commit {android_commit}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
