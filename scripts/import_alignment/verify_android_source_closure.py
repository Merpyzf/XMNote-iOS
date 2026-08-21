#!/usr/bin/env python3
"""Freeze or verify the Android import production-source closure without editing Android."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


DEFAULT_ANDROID_ROOT = Path("/Users/wangke/Workspace/AndroidProjects/XMNote")
SCRIPT_ROOT = Path(__file__).resolve().parent
DEFAULT_BASELINE = SCRIPT_ROOT / "android-source-closure.json"

EXACT_PATHS = {
    "app/src/main/java/com/merpyzf/xmnote/mvp/presenter/data/NotesLoadPresenter.kt",
    "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/NotesLoadActivity.kt",
    "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/KindleImportParseGateway.kt",
    "common/src/main/java/com/merpyzf/common/constant/AppConstant.java",
    "common/src/main/java/com/merpyzf/common/helper/setting/SpSettingHelper.kt",
    "common/src/main/java/com/merpyzf/common/model/dto/api/SendBookDto.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/AttachImage.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Book.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Chapter.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Group.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Note.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Review.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/ReviewImage.kt",
    "common/src/main/java/com/merpyzf/common/model/vo/Tag.kt",
    "common/src/main/java/com/merpyzf/common/utils/DateUtil.kt",
    "common/src/main/java/com/merpyzf/common/utils/DateUtils.java",
    "common/src/main/java/com/merpyzf/common/utils/RegexHelper.kt",
    "common/src/main/java/com/merpyzf/common/utils/extensions/StringExtensions.kt",
    "common/src/main/java/com/merpyzf/common/utils/extensions/UriExt.kt",
    "data/src/main/java/com/merpyzf/data/helper/NoteContentHashHelper.kt",
    "data/src/main/java/com/merpyzf/data/helper/NoteImportHashManager.kt",
    "data/src/main/java/com/merpyzf/data/repository/BookRepository.kt",
    "data/src/main/java/com/merpyzf/data/repository/ChapterImportSession.kt",
    "data/src/main/java/com/merpyzf/data/repository/ImportedChapterIdentity.kt",
    "data/src/main/java/com/merpyzf/data/repository/ImportedChapterIdentityProtector.kt",
    "data/src/main/java/com/merpyzf/data/repository/KindleImportMergePolicy.kt",
    "data/src/main/java/com/merpyzf/data/repository/NoteRepository.kt",
}

PREFIXES = (
    "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/kindle/",
    "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/weread/",
    "app/src/main/java/com/merpyzf/xmnote/viewmodel/data/WeRead",
    "app/src/main/java/com/merpyzf/xmnote/helper/WeRead",
    "app/src/main/java/com/merpyzf/xmnote/mvp/contract/data/WeRead",
    "app/src/main/java/com/merpyzf/xmnote/mvp/presenter/data/WeRead",
    "common/src/main/java/com/merpyzf/common/model/dto/note_import/",
    "common/src/main/java/com/merpyzf/common/model/dto/weread/",
    "common/src/main/java/com/merpyzf/common/model/dto/weread_web/",
    "common/src/main/java/com/merpyzf/common/model/http/WeRead",
    "common/src/main/java/com/merpyzf/common/model/vo/WeRead",
    "common/src/main/java/com/merpyzf/common/model/widget/WeRead",
    "common/src/main/java/com/merpyzf/common/service/weread/",
    "data/src/main/java/com/merpyzf/data/helper/note_parse_helper/",
    "data/src/main/java/com/merpyzf/data/repository/WeRead",
    "data/src/main/java/com/merpyzf/data/entity/query/note/WeRead",
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--android-root",
        type=Path,
        default=Path(os.environ.get("XMNOTE_ANDROID_ROOT", DEFAULT_ANDROID_ROOT)),
    )
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--freeze", action="store_true")
    return parser.parse_args()


def discover_files(root: Path) -> list[str]:
    discovered = set(EXACT_PATHS)
    repository_files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        text=True,
    ).splitlines()
    for relative in repository_files:
        if relative.endswith((".kt", ".java")) and relative.startswith(PREFIXES):
            discovered.add(relative)
    missing = sorted(path for path in discovered if not (root / path).is_file())
    if missing:
        raise RuntimeError("Android source closure 缺少文件:\n" + "\n".join(missing))
    return sorted(discovered)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def git_head(root: Path) -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()


def snapshot(root: Path) -> dict[str, object]:
    files = discover_files(root)
    return {
        "schemaVersion": 1,
        "androidCommit": git_head(root),
        "files": [
            {"path": relative, "sha256": sha256(root / relative)}
            for relative in files
        ],
    }


def verify(root: Path, baseline_path: Path) -> int:
    frozen = json.loads(baseline_path.read_text(encoding="utf-8"))
    current = snapshot(root)
    frozen_files = {item["path"]: item["sha256"] for item in frozen["files"]}
    current_files = {item["path"]: item["sha256"] for item in current["files"]}
    added = sorted(current_files.keys() - frozen_files.keys())
    removed = sorted(frozen_files.keys() - current_files.keys())
    changed = sorted(
        path
        for path in current_files.keys() & frozen_files.keys()
        if current_files[path] != frozen_files[path]
    )
    if added or removed or changed:
        print("Android 书摘导入源码闭包已漂移，禁止报告对齐通过。", file=sys.stderr)
        print(
            f"冻结提交: {frozen['androidCommit']}\n当前提交: {current['androidCommit']}",
            file=sys.stderr,
        )
        for label, paths in (("新增", added), ("移除", removed), ("变化", changed)):
            for path in paths:
                print(f"{label}: {path}", file=sys.stderr)
        return 1
    print(
        "Android 书摘导入源码闭包未漂移 "
        f"({len(current_files)} files, baseline {frozen['androidCommit']}, current {current['androidCommit']})"
    )
    return 0


def main() -> int:
    arguments = parse_arguments()
    root = arguments.android_root.resolve()
    if not (root / ".git").exists():
        print(f"Android 工程不可用: {root}", file=sys.stderr)
        return 2
    if arguments.freeze:
        payload = snapshot(root)
        arguments.baseline.parent.mkdir(parents=True, exist_ok=True)
        arguments.baseline.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"已冻结 {len(payload['files'])} 个 Android 导入生产文件 -> {arguments.baseline}"
        )
        return 0
    if not arguments.baseline.is_file():
        print(f"缺少冻结基线: {arguments.baseline}", file=sys.stderr)
        return 2
    return verify(root, arguments.baseline)


if __name__ == "__main__":
    raise SystemExit(main())
