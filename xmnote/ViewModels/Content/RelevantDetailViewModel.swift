/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取相关详情并执行硬删除事务
 * [OUTPUT]: 对外提供 RelevantDetailViewModel，驱动相关单页详情查看与删除流程
 * [POS]: Content 模块相关查看状态源，承接时间线进入的相关内容全屏详情页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 相关详情状态源，负责加载、刷新和删除单条相关内容。
final class RelevantDetailViewModel {
    let contentId: Int64

    var detail: RelevantContentDetail?
    var isLoading = false
    var isDeleting = false
    var errorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private let repository: any ContentRepositoryProtocol

    /// 注入相关内容 ID 与内容仓储，初始化单页详情上下文。
    init(contentId: Int64, repository: any ContentRepositoryProtocol) {
        self.contentId = contentId
        self.repository = repository
    }

    /// 读取或刷新当前相关内容详情。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let payload = try await repository.fetchViewerDetail(itemID: .relevant(contentId)) else {
                detail = nil
                errorMessage = "相关内容不存在或已删除"
                return
            }
            guard case .relevant(let relevantDetail) = payload else {
                detail = nil
                errorMessage = "相关内容数据类型不匹配"
                return
            }
            detail = relevantDetail
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 删除当前相关内容，成功后请求退出详情页。
    func deleteCurrentRelevant() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await repository.delete(itemID: .relevant(contentId))
            dismissalRequestToken &+= 1
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
