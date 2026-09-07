/**
 * [INPUT]: 依赖 Foundation，接收系统文件选择器授予的 URL
 * [OUTPUT]: 提供导入文件访问票据、文件元数据与可取消的顺序读取
 * [POS]: Data/Repositories 的导入输入读取边界，不参与解析和数据库写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 在待导入清单与异步读取期间保持文件授权，最后一个持有者释放后归还访问权限。
nonisolated final class NoteImportFileAccess: Sendable {
    let url: URL
    let byteCount: Int?
    private let didAccess: Bool

    /// 获取文件选择器的授权并记录展示元数据；不读取正文。
    init(url: URL) {
        self.url = url
        didAccess = url.startAccessingSecurityScopedResource()
        byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    deinit {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
}

/// 顺序读取外部导入文件，避免主线程文件 I/O 和整批文件同时占用内存。
actor NoteImportFileRepository {
    /// 在仓储隔离域分块读取；每块检查父任务取消，票据在整个读取期间保持 security scope。
    func read(_ file: NoteImportFileAccess) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
        }
        try Task.checkCancellation()
        return data
    }
}
