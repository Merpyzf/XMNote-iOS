/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取书评详情并执行硬删除事务
 * [OUTPUT]: 对外提供 ReviewDetailViewModel，驱动书评单页详情查看与删除流程
 * [POS]: Content 模块书评查看状态源，承接时间线进入的书评全屏详情页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 书评详情状态源，负责加载、刷新和删除单条书评。
final class ReviewDetailViewModel {
    let reviewId: Int64

    var detail: ReviewContentDetail?
    var isLoading = false
    var isDeleting = false
    var errorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private let repository: any ContentRepositoryProtocol

    /// 注入书评 ID 与内容仓储，初始化单页详情上下文。
    init(reviewId: Int64, repository: any ContentRepositoryProtocol) {
        self.reviewId = reviewId
        self.repository = repository
    }

    /// 读取或刷新当前书评详情。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let payload = try await repository.fetchViewerDetail(itemID: .review(reviewId)) else {
                detail = nil
                errorMessage = "书评不存在或已删除"
                return
            }
            guard case .review(let reviewDetail) = payload else {
                detail = nil
                errorMessage = "书评数据类型不匹配"
                return
            }
            detail = reviewDetail
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 删除当前书评，成功后请求退出详情页。
    func deleteCurrentReview() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await repository.delete(itemID: .review(reviewId))
            dismissalRequestToken &+= 1
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
