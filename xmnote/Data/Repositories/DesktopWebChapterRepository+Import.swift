/**
 * [INPUT]: 依赖 DesktopWebChapterRepository 的有效章节树、AppDatabase/GRDB 写事务与 Android 目录文本合同
 * [OUTPUT]: 对外提供 ChapterController 目录导入预览、重复检测和选择性事务提交
 * [POS]: Data 层网页章节导入扩展；复刻 Android 键生成、层级、计数与既有选择异常
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebChapterImportNodeDto 的 App 层递归投影。
nonisolated struct DesktopWebChapterImportNodeSnapshot: Sendable, Equatable {
    let key: String
    let title: String
    let depth: Int
    let duplicate: Bool
    let selected: Bool
    let children: [DesktopWebChapterImportNodeSnapshot]
}

/// WebChapterImportPreviewDto 的 App 层投影。
nonisolated struct DesktopWebChapterImportPreviewSnapshot: Sendable, Equatable {
    let items: [DesktopWebChapterImportNodeSnapshot]
    let totalCount: Int
    let selectableCount: Int
    let duplicateCount: Int
    let selectedCount: Int
}

/// WebChapterImportCommitResultDto 的 App 层投影。
nonisolated struct DesktopWebChapterImportCommitResultSnapshot: Sendable, Equatable {
    let created: Int
    let skipped: Int
    let duplicated: Int
}

nonisolated extension DesktopWebChapterRepository {
    /// 解析目录并根据有效、树可达的既有路径标记重复项；空目录返回全零预览。
    func previewImport(
        bookID: Int64,
        catalog: String
    ) async throws -> DesktopWebChapterImportPreviewSnapshot {
        try await requireActiveBook(bookID)
        let parsed = try Self.parseImportCatalog(catalog)
        guard !parsed.isEmpty else {
            return DesktopWebChapterImportPreviewSnapshot(
                items: [],
                totalCount: 0,
                selectableCount: 0,
                duplicateCount: 0,
                selectedCount: 0
            )
        }
        let existing = try await existingChapterPaths(bookID: bookID)
        var seenPaths: Set<String> = []
        let items = parsed.map { node in
            Self.previewNode(
                node,
                existing: existing,
                seenPaths: &seenPaths,
                parentPath: []
            )
        }
        let flattened = Self.flattenImportPreview(items)
        let duplicateCount = flattened.filter(\.duplicate).count
        let selectableCount = flattened.count { !$0.duplicate }
        return DesktopWebChapterImportPreviewSnapshot(
            items: items,
            totalCount: flattened.count,
            selectableCount: selectableCount,
            duplicateCount: duplicateCount,
            selectedCount: flattened.filter(\.selected).count
        )
    }

    /// 在单事务内创建选中节点及其必要祖先；任意深度后代被选中时都会保留祖先路径。
    func commitImport(
        bookID: Int64,
        catalog: String,
        selectedKeys rawSelectedKeys: [String]
    ) async throws -> DesktopWebChapterImportCommitResultSnapshot {
        try await requireActiveBook(bookID)
        let parsed = try Self.parseImportCatalog(catalog)
        guard !parsed.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("目录内容不能为空")
        }
        let selectedKeys = Set(rawSelectedKeys)
        guard !selectedKeys.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("请至少选择一个章节")
        }

        let now = currentTimeMillis()
        let initialExisting = try await existingChapterPaths(bookID: bookID)
        return try await database.dbPool.write { db in
            var existing = initialExisting
            var created = 0
            var duplicated = 0
            var skipped = 0
            func commitNode(
                _ node: ParsedImportNode,
                parentID: Int64,
                parentPath: [String]
            ) throws -> Int64? {
                let subtreeSelected = Self.importSubtreeSelected(node, selectedKeys: selectedKeys)
                guard subtreeSelected else {
                    skipped += Self.countImportNodes(node)
                    return nil
                }

                let pathTitles = parentPath + [node.title]
                let pathKey = pathTitles.joined(separator: Self.pathSeparator)
                let nodeID: Int64
                if let existingChapter = existing[pathKey], let existingID = existingChapter.id {
                    if selectedKeys.contains(node.key) {
                        duplicated += 1
                    }
                    nodeID = existingID
                } else {
                    let chapter = try Self.insertImportedChapter(
                        db: db,
                        bookID: bookID,
                        parentID: parentID,
                        title: node.title,
                        now: now
                    )
                    nodeID = chapter.id ?? 0
                    existing[pathKey] = chapter
                    created += 1
                }
                for child in node.children {
                    _ = try commitNode(child, parentID: nodeID, parentPath: pathTitles)
                }
                return nodeID
            }

            for root in parsed {
                _ = try commitNode(root, parentID: 0, parentPath: [])
            }
            return DesktopWebChapterImportCommitResultSnapshot(
                created: created,
                skipped: skipped,
                duplicated: duplicated
            )
        }
    }
}

private nonisolated extension DesktopWebChapterRepository {
    struct ParsedImportNode: Sendable, Equatable {
        let key: String
        let title: String
        let depth: Int
        var children: [ParsedImportNode]
    }

    static func importSubtreeSelected(
        _ node: ParsedImportNode,
        selectedKeys: Set<String>
    ) -> Bool {
        selectedKeys.contains(node.key)
            || node.children.contains { importSubtreeSelected($0, selectedKeys: selectedKeys) }
    }

    static func parseImportCatalog(_ catalog: String) throws -> [ParsedImportNode] {
        let lines = catalog.components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\u{200D}", with: "")
            }
            .filter { !isImportBlank($0) }
        guard !lines.isEmpty else { return [] }

        var roots: [ParsedImportNode] = []
        var pathsByLevel: [Int: [Int]] = [:]
        var siblingIndexes: [Int: Int] = [:]
        for rawLine in lines {
            let title = kotlinTrimmed(rawLine)
            guard !title.isEmpty else { continue }
            let level = measureImportLevel(rawLine)
            guard level <= maxDepth else {
                throw DesktopWebCatalogRepositoryError.invalidArgument(
                    "章节层级不能超过 \(maxDepth) 层"
                )
            }
            let depth = level - 1
            let order = siblingIndexes[level, default: 0]
            siblingIndexes[level] = order + 1
            Array(siblingIndexes.keys.filter { $0 > level }).forEach {
                siblingIndexes.removeValue(forKey: $0)
            }

            let parentPath = level == 1 ? nil : pathsByLevel[level - 1]
            if level > 1, parentPath == nil {
                throw DesktopWebCatalogRepositoryError.invalidArgument(
                    "第 \(level) 层章节缺少父章节：\(title)"
                )
            }
            let parentKey = parentPath.map { parsedNode(at: $0, in: roots).key + "-" } ?? "p-"
            let newNode = ParsedImportNode(
                key: parentKey + "\(depth)-\(order)",
                title: title,
                depth: depth,
                children: []
            )
            let insertedPath: [Int]
            if let parentPath {
                insertedPath = append(newNode, to: parentPath, roots: &roots)
            } else {
                roots.append(newNode)
                insertedPath = [roots.count - 1]
            }
            pathsByLevel[level] = insertedPath
            Array(pathsByLevel.keys.filter { $0 > level }).forEach {
                pathsByLevel.removeValue(forKey: $0)
            }
        }
        return roots
    }

    static func append(
        _ node: ParsedImportNode,
        to parentPath: [Int],
        roots: inout [ParsedImportNode]
    ) -> [Int] {
        func appendRecursively(
            _ node: ParsedImportNode,
            path: ArraySlice<Int>,
            nodes: inout [ParsedImportNode]
        ) -> [Int] {
            guard let index = path.first else { return [] }
            if path.count == 1 {
                nodes[index].children.append(node)
                return [index, nodes[index].children.count - 1]
            }
            let childPath = appendRecursively(
                node,
                path: path.dropFirst(),
                nodes: &nodes[index].children
            )
            return [index] + childPath
        }
        return appendRecursively(node, path: parentPath[...], nodes: &roots)
    }

    static func parsedNode(at path: [Int], in roots: [ParsedImportNode]) -> ParsedImportNode {
        var node = roots[path[0]]
        for index in path.dropFirst() {
            node = node.children[index]
        }
        return node
    }

    static func measureImportLevel(_ line: String) -> Int {
        let characters = Array(line)
        var level = 1
        var index = 0
        while index < characters.count {
            if index + 1 < characters.count,
               characters[index] == "\u{3000}",
               characters[index + 1] == "\u{3000}" {
                level += 1
                index += 2
            } else if characters[index] == "\t" {
                level += 1
                index += 1
            } else if index + 1 < characters.count,
                      characters[index] == " ",
                      characters[index + 1] == " " {
                level += 1
                index += 2
            } else if characters[index] == " " || characters[index] == "\u{3000}" {
                index += 1
            } else {
                return level
            }
        }
        return level
    }

    static func isImportBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    static func kotlinTrimmed(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var lower = 0
        var upper = scalars.count
        while lower < upper, isKotlinWhitespace(scalars[lower]) { lower += 1 }
        while upper > lower, isKotlinWhitespace(scalars[upper - 1]) { upper -= 1 }
        var result = String.UnicodeScalarView()
        scalars[lower..<upper].forEach { result.append($0) }
        return String(result)
    }

    static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return (0x0009...0x000D).contains(scalar.value)
                || (0x001C...0x001F).contains(scalar.value)
        }
    }

    func existingChapterPaths(bookID: Int64) async throws -> [String: ChapterRecord] {
        let records = try await allChapters(bookID: bookID)
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let reachable = Self.flatten(Self.fullTree(records: records, noteCounts: [:]))
        var result: [String: ChapterRecord] = [:]
        for chapter in reachable {
            if let record = byID[chapter.id] {
                result[chapter.pathTitles.joined(separator: Self.pathSeparator)] = record
            }
        }
        return result
    }

    static func previewNode(
        _ node: ParsedImportNode,
        existing: [String: ChapterRecord],
        seenPaths: inout Set<String>,
        parentPath: [String]
    ) -> DesktopWebChapterImportNodeSnapshot {
        let path = parentPath + [node.title]
        let pathKey = path.joined(separator: pathSeparator)
        let isFirst = seenPaths.insert(pathKey).inserted
        let duplicate = !isFirst || existing[pathKey] != nil
        var children: [DesktopWebChapterImportNodeSnapshot] = []
        for child in node.children {
            children.append(
                previewNode(child, existing: existing, seenPaths: &seenPaths, parentPath: path)
            )
        }
        return DesktopWebChapterImportNodeSnapshot(
            key: node.key,
            title: node.title,
            depth: node.depth,
            duplicate: duplicate,
            selected: !duplicate,
            children: children
        )
    }

    static func flattenImportPreview(
        _ items: [DesktopWebChapterImportNodeSnapshot]
    ) -> [DesktopWebChapterImportNodeSnapshot] {
        items.flatMap { [$0] + flattenImportPreview($0.children) }
    }

    static func countImportNodes(_ node: ParsedImportNode) -> Int {
        1 + node.children.reduce(0) { $0 + countImportNodes($1) }
    }

    static func insertImportedChapter(
        db: Database,
        bookID: Int64,
        parentID: Int64,
        title: String,
        now: Int64
    ) throws -> ChapterRecord {
        // SQL 目的：读取导入节点同书同父有效章节的最大顺序。
        // 涉及表：chapter；关键过滤：book_id、parent_id、is_deleted = 0。
        // 时间字段：无；返回字段用于按 Android Int 溢出语义追加顺序。
        let rawOrder = try Int64.fetchOne(
            db,
            sql: "SELECT IFNULL(MAX(chapter_order), 0) FROM chapter WHERE book_id = ? AND parent_id = ? AND is_deleted = 0",
            arguments: [bookID, parentID]
        ) ?? 0
        let order = Int32(truncatingIfNeeded: rawOrder) &+ 1
        // SQL 目的：在同一导入事务内重读全部有效章节，确保先创建祖先可被后续子节点发现。
        // 涉及表：chapter；关键过滤：book_id、id != 0、is_deleted = 0。
        // 时间字段：无；返回字段用于计算层级与 source_path。
        let records = try ChapterRecord.fetchAll(
            db,
            sql: "SELECT * FROM chapter WHERE id != 0 AND book_id = ? AND is_deleted = 0 ORDER BY parent_id ASC, chapter_order ASC",
            arguments: [bookID]
        )
        let parentPath = ancestorPath(records: records, chapterID: parentID)
        let level = parentPath.count + 1
        guard (1...maxDepth).contains(level) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节层级不能超过 \(maxDepth) 层"
            )
        }
        var record = ChapterRecord(
            bookId: bookID,
            parentId: parentID,
            title: title,
            chapterOrder: Int64(order),
            chapterLevel: Int64(level),
            sourceUid: "",
            sourceAnchor: "",
            sourcePath: (parentPath.map(\.title) + [title]).joined(separator: pathSeparator),
            createdDate: now
        )
        try record.insert(db)
        return record
    }
}
