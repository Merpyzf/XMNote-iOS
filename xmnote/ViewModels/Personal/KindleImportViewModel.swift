/**
 * [INPUT]: 依赖 Observation、KindleImportGatewayProtocol 与系统文件选择结果
 * [OUTPUT]: 对外提供 KindleImportViewModel，编排文件选择后的解析、取消、错误和预览状态
 * [POS]: ViewModels/Personal 的 Kindle 导入页面状态 owner，不直接读取文件或访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// Kindle 文件导入状态模型；MainActor 串行保护页面状态，取消后旧任务不会回写预览。
@MainActor
@Observable
final class KindleImportViewModel {
    var isParsing = false
    var parsedBooks: [NoteImportDraftBook] = []
    var opensPreview = false
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let gateway: any KindleImportGatewayProtocol

    init(gateway: any KindleImportGatewayProtocol) {
        self.gateway = gateway
    }

    /// 启动单次导入；新选择会取消旧任务，并在每个 await 后检查取消，防止旧结果覆盖新选择。
    func importFile(at url: URL, entryPoint: KindleImportEntryPoint) {
        task?.cancel()
        isParsing = true
        errorMessage = nil
        task = Task {
            do {
                let books = try await gateway.parse(url: url, entryPoint: entryPoint)
                try Task.checkCancellation()
                parsedBooks = books
                opensPreview = true
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            isParsing = false
        }
    }

    /// 页面离场时终止文件复制或解析，并立即恢复可交互状态。
    func cancel() {
        task?.cancel()
        task = nil
        isParsing = false
    }
}
