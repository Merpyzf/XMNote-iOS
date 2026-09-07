/**
 * [INPUT]: 依赖统一 ExportRepository、DesktopWebExportPort DTO、实时 AppState 会员 provider 与 ZIPFoundation
 * [OUTPUT]: 对外提供 DesktopWebUnifiedExportAdapter，把兼容书摘及新增书籍导出路由映射到统一领域请求
 * [POS]: Infra/DesktopWeb 的兼容适配器；HTTP 路由不再自行读取数据库、设置或生成文件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb
import ZIPFoundation

/// Web Adapter 不持有可变业务状态；每次请求从 AppState provider 冻结会员快照后调用统一 Repository。
final class DesktopWebUnifiedExportAdapter: DesktopWebExportPort, @unchecked Sendable {
    private let repository: ExportRepository
    private let isPremiumProvider: @Sendable () async -> Bool

    init(
        repository: ExportRepository,
        isPremiumProvider: @escaping @Sendable () async -> Bool
    ) {
        self.repository = repository
        self.isPremiumProvider = isPremiumProvider
    }

    /// 复用统一 Repository 的思源连接设置和 Keychain 凭据。
    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption] {
        try await repository.siYuanNotebooks()
    }

    /// 复用统一 Repository 的 Obsidian 安全连接设置和 Keychain 凭据。
    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption] {
        try await repository.obsidianDirectories()
    }

    /// 把兼容请求映射为领域请求，本地多个产物从磁盘逐项加入 ZIP 后再返回 HTTP 文件合同。
    func exportNotesLocally(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebExportFile {
        let target = try Self.target(request.target)
        guard target.isLocalFile, target != .csv else {
            throw DesktopWebAPIError(code: 40_001, message: "不支持的书摘本地目标：\(request.target)")
        }
        var settings = try await repository.settings()
        settings.content = Self.content(request.content)
        let result = await repository.export(
            ExportRequest(
                kind: .noteExcerpt,
                scope: request.bookIds.isEmpty ? .allBooks : .bookIDs(request.bookIds),
                target: target,
                settings: settings,
                isPremium: await isPremiumProvider()
            ),
            progress: { _ in }
        )
        guard let ticket = result.artifactTicket else {
            throw Self.error(from: result)
        }
        defer { ticket.cleanup() }
        if ticket.artifacts.count == 1, let artifact = ticket.artifacts.first {
            return DesktopWebExportFile(
                fileName: artifact.fileName,
                mediaType: artifact.mediaType,
                data: try Data(contentsOf: artifact.fileURL, options: .mappedIfSafe)
            )
        }
        return try Self.makeZIP(ticket.artifacts)
    }

    /// 远端结果保持既有逐书失败 DTO，同时由 Repository 执行第二层会员校验和结果不确定分类。
    func exportNotesRemotely(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebRemoteExportResult {
        let target = try Self.target(request.target)
        guard !target.isLocalFile else {
            throw DesktopWebAPIError(code: 40_001, message: "不支持的书摘远端目标：\(request.target)")
        }
        var settings = try await repository.settings()
        settings.content = Self.content(request.content)
        let result = await repository.export(
            ExportRequest(
                kind: .noteExcerpt,
                scope: request.bookIds.isEmpty ? .allBooks : .bookIDs(request.bookIds),
                target: target,
                settings: settings,
                isPremium: await isPremiumProvider()
            ),
            progress: { _ in }
        )
        if result.requestedBookCount == 0, result.successCount == 0, !result.failures.isEmpty {
            throw Self.error(from: result)
        }
        return DesktopWebRemoteExportResult(
            total: result.requestedBookCount,
            successCount: result.successCount,
            failCount: result.failures.count,
            failedItems: result.failures.map {
                DesktopWebRemoteExportFailedItem(
                    bookId: $0.bookID ?? 0,
                    bookName: $0.bookName ?? "",
                    reason: $0.disposition == .resultUncertain
                        ? "\($0.message)（结果不确定，请先检查远端）"
                        : $0.message
                )
            }
        )
    }

    /// 新增书籍信息本地路由仅接受 CSV，并复用 Repository 的字段顺序、开关和文件名规则。
    func exportBooksLocally(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebExportFile {
        guard request.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "csv" else {
            throw DesktopWebAPIError(code: 40_001, message: "书籍信息本地导出仅支持 CSV")
        }
        let result = await repository.export(
            ExportRequest(
                kind: .bookInformation,
                scope: request.bookIds.isEmpty ? .allBooks : .bookIDs(request.bookIds),
                target: .csv,
                settings: try await repository.settings(),
                isPremium: await isPremiumProvider()
            ),
            progress: { _ in }
        )
        guard let ticket = result.artifactTicket, let artifact = ticket.artifacts.first else {
            throw Self.error(from: result)
        }
        defer { ticket.cleanup() }
        return .init(
            fileName: artifact.fileName,
            mediaType: artifact.mediaType,
            data: try Data(contentsOf: artifact.fileURL, options: .mappedIfSafe)
        )
    }

    /// 新增书籍信息远端路由只接受 Notion，并保留逐书结构化结果。
    func exportBooksRemotely(_ request: DesktopWebBookExportRequest) async throws -> DesktopWebRemoteExportResult {
        guard request.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "notion" else {
            throw DesktopWebAPIError(code: 40_001, message: "书籍信息远端导出仅支持 Notion")
        }
        let result = await repository.export(
            ExportRequest(
                kind: .bookInformation,
                scope: request.bookIds.isEmpty ? .allBooks : .bookIDs(request.bookIds),
                target: .notion,
                settings: try await repository.settings(),
                isPremium: await isPremiumProvider()
            ),
            progress: { _ in }
        )
        if result.requestedBookCount == 0, result.successCount == 0, !result.failures.isEmpty {
            throw Self.error(from: result)
        }
        return DesktopWebRemoteExportResult(
            total: result.requestedBookCount,
            successCount: result.successCount,
            failCount: result.failures.count,
            failedItems: result.failures.map {
                .init(
                    bookId: $0.bookID ?? 0,
                    bookName: $0.bookName ?? "",
                    reason: $0.message
                )
            }
        )
    }

    /// 兼容旧 Web 标识并拒绝任何未知或已移除目标。
    private static func target(_ rawValue: String) throws -> ExportTarget {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target: ExportTarget? = switch normalized {
        case "onenote": .oneNote
        case "siyuan": .siYuan
        default: ExportTarget(rawValue: normalized)
        }
        guard let target, target.supports(.noteExcerpt) else {
            throw DesktopWebAPIError(code: 40_001, message: "不支持的导出目标：\(rawValue)")
        }
        return target
    }

    /// 映射旧 Web 内容选择到统一不可变快照。
    private static func content(_ value: DesktopWebExportContentSelection) -> ExportContentSelection {
        ExportContentSelection(
            includesNotes: value.note,
            includesRelatedNotes: value.relevant,
            includesReviews: value.review
        )
    }

    /// 目标级失败转换为 Web 业务错误，不包含 Keychain 或请求 Header 内容。
    private static func error(from result: ExportResult) -> DesktopWebAPIError {
        let message = result.failures.first?.message ?? "导出失败"
        return DesktopWebAPIError(code: 40_001, message: message)
    }

    /// 从磁盘文件逐项构建 ZIP，避免先把全部文件再次拼成内存数组。
    private static func makeZIP(_ artifacts: [ExportArtifact]) throws -> DesktopWebExportFile {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "desktop_web_export_\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let archive = try? Archive(url: url, accessMode: .create) else {
            throw DesktopWebAPIError(code: 50_001, message: "导出压缩包创建失败")
        }
        for artifact in artifacts {
            let fileSize = (try FileManager.default.attributesOfItem(atPath: artifact.fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: artifact.fileURL)
            defer { try? handle.close() }
            try archive.addEntry(
                with: artifact.fileName,
                type: .file,
                uncompressedSize: fileSize,
                provider: { position, size in
                    try handle.seek(toOffset: UInt64(position))
                    return try handle.read(upToCount: size) ?? Data()
                }
            )
        }
        return DesktopWebExportFile(
            fileName: "书摘导出.zip",
            mediaType: "application/zip",
            data: try Data(contentsOf: url, options: .mappedIfSafe)
        )
    }
}
