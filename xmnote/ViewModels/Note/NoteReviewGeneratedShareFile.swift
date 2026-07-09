/**
 * [INPUT]: 接收书摘回顾分享图渲染后的临时 PNG 文件信息
 * [OUTPUT]: 对外提供 NoteReviewGeneratedShareFile，供 NoteReviewViewModel 后续接入分享或相册保存流程
 * [POS]: ViewModels/Note 的书摘回顾分享图文件封装，隔离渲染结果与具体 UI 集成
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘回顾分享图的临时文件描述，集中保存后续分享、保存相册或清理文件所需的稳定元信息。
nonisolated struct NoteReviewGeneratedShareFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let noteID: Int64
    let title: String
    let fileURL: URL
    let fileName: String
    let contentType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    /// 构造 PNG 文件封装；调用方负责在分享流程结束后按业务需要清理临时文件。
    init(
        id: UUID = UUID(),
        noteID: Int64,
        title: String,
        fileURL: URL,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int
    ) {
        self.id = id
        self.noteID = noteID
        self.title = title
        self.fileURL = fileURL
        self.fileName = fileName
        self.contentType = "image/png"
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

/// 书摘回顾分享图保存阶段错误，供 ViewModel 映射为用户反馈。
nonisolated enum NoteReviewShareImageSaveError: LocalizedError, Equatable, Sendable {
    case photoLibraryPermissionDenied

    var errorDescription: String? {
        switch self {
        case .photoLibraryPermissionDenied:
            return "没有相册写入权限，无法保存分享图"
        }
    }
}
