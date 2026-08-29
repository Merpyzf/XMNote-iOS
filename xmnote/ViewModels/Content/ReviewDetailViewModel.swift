/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取书评详情并执行 Android v45 对齐的软删除事务
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
    private(set) var isMissing = false
    private(set) var loadErrorMessage: String?
    private(set) var operationErrorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private let repository: any ContentRepositoryProtocol

    /// 注入书评 ID 与内容仓储，初始化单页详情上下文。
    init(reviewId: Int64, repository: any ContentRepositoryProtocol) {
        self.reviewId = reviewId
        self.repository = repository
    }

    /// 读取或刷新当前书评详情。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        isMissing = false
        loadErrorMessage = nil
        defer { isLoading = false }

        do {
            guard let payload = try await repository.fetchViewerDetail(itemID: .review(reviewId)) else {
                detail = nil
                isMissing = true
                return
            }
            guard case .review(let reviewDetail) = payload else {
                detail = nil
                loadErrorMessage = "暂时无法加载书评"
                return
            }
            detail = reviewDetail
            operationErrorMessage = nil
        } catch {
            loadErrorMessage = "暂时无法加载书评"
        }
    }

    /// 删除当前书评，成功后请求退出详情页。
    func deleteCurrentReview() async {
        guard !isDeleting else { return }
        isDeleting = true
        operationErrorMessage = nil
        defer { isDeleting = false }

        do {
            try await repository.delete(itemID: .review(reviewId))
            dismissalRequestToken &+= 1
        } catch {
            operationErrorMessage = "删除书评失败"
        }
    }
}
