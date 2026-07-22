/**
 * [INPUT]: 依赖 Foundation，接收滴墨等来源解析出的远端附件 URL
 * [OUTPUT]: 对外提供 NoteImportAttachmentImporter，生产可转存对象存储、测试可返回固定 fixture URL
 * [POS]: Domain/Repositories 的书摘导入副作用边界，隔离 Parser 与网络、文件和对象存储
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated protocol NoteImportAttachmentImporter: Sendable {
    /// 导入单个附件；调用方负责将失败按对应 Android Parser 的跳过语义处理，取消必须向上传播。
    func importAttachment(from sourceURL: URL) async throws -> URL?
}

/// 生产兜底保留可访问的远端附件 URL；对象存储转存由导入提交阶段按配置尽力执行。
nonisolated struct PassthroughNoteImportAttachmentImporter: NoteImportAttachmentImporter {
    func importAttachment(from sourceURL: URL) async throws -> URL? { sourceURL }
}

/// 滴墨生产附件导入器：下载到临时目录后通过现有 S3 能力转存，任一步失败由 Parser 按 Android 语义跳过。
final class S3NoteImportAttachmentImporter: NoteImportAttachmentImporter, @unchecked Sendable {
    private let repository: any S3UploadRepositoryProtocol

    init(repository: any S3UploadRepositoryProtocol) { self.repository = repository }

    nonisolated func importAttachment(from sourceURL: URL) async throws -> URL? {
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("dimo_\(UUID().uuidString).\(ext)")
        try data.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }
        return try await repository.uploadFile(localURL: localURL, prefix: "note_attach", progress: nil).remoteURL
    }
}
