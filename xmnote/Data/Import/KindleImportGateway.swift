/**
 * [INPUT]: 依赖 NoteImportRepositoryProtocol、NoteImportParserRegistry 与 Kindle 系统文件 URL
 * [OUTPUT]: 对外提供 KindleImportGatewayProtocol 和默认实现，统一连接设备与普通文件选择入口
 * [POS]: Data/Import 的 Kindle 平台适配网关，系统取数完成后只调用同一个生产 Parser
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Kindle 文件的用户入口只影响引导文案，不改变文件约束、解析器或落库链路。
nonisolated enum KindleImportEntryPoint: Hashable, Sendable {
    case connectedDevice
    case manualFile
}

/// Kindle 平台取数与解析边界，便于证明两个入口复用同一个解析网关。
@MainActor
protocol KindleImportGatewayProtocol {
    /// 读取系统授予的文件并调用 Kindle My Clippings Parser；取消会贯穿复制和解析任务。
    func parse(url: URL, entryPoint: KindleImportEntryPoint) async throws -> [NoteImportDraftBook]
}

/// Kindle 网关只依赖 Repository 暴露的受控文件读取能力，测试可替换输入而不绕过生产 Parser。
@MainActor
protocol KindleImportFileLoading {
    func loadKindleClippingsFile(from url: URL) async throws -> Data
}

extension NoteImportRepository: KindleImportFileLoading {}

/// 生产 Kindle 网关；iOS 只接收“文件”公开的外部文档，不伪造 MTP 自动枚举能力。
@MainActor
final class DefaultKindleImportGateway: KindleImportGatewayProtocol {
    private let fileLoader: any KindleImportFileLoading
    private let registry = NoteImportParserRegistry(
        attachmentImporter: PassthroughNoteImportAttachmentImporter()
    )

    init(repository: any NoteImportRepositoryProtocol) {
        self.fileLoader = RepositoryKindleImportFileLoader(repository: repository)
    }

    init(fileLoader: any KindleImportFileLoading) {
        self.fileLoader = fileLoader
    }

    func parse(url: URL, entryPoint _: KindleImportEntryPoint) async throws -> [NoteImportDraftBook] {
        guard url.lastPathComponent.caseInsensitiveCompare("My Clippings.txt") == .orderedSame else {
            throw KindleImportFileError.invalidFileName
        }
        let data = try await fileLoader.loadKindleClippingsFile(from: url)
        try Task.checkCancellation()
        let books = try await registry.parse(
            data: data,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension,
            using: .kindle
        )
        guard !books.isEmpty else { throw NoteImportParserError.noteNotFound }
        return books.map { draft in
            var value = draft
            value.source = 2
            return value
        }
    }
}

/// 将完整 Repository 契约缩窄成 Kindle 文件读取能力，确保 ViewModel 仍不直接接触文件系统。
@MainActor
private struct RepositoryKindleImportFileLoader: KindleImportFileLoading {
    let repository: any NoteImportRepositoryProtocol

    func loadKindleClippingsFile(from url: URL) async throws -> Data {
        try await repository.loadKindleClippingsFile(from: url)
    }
}
