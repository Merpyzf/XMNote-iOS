/**
 * [INPUT]: 依赖 Foundation（Date/URL）与 Observation，解析 scene 根层接收的阅读计时深链
 * [OUTPUT]: 对外提供 ReadingRoute 浏览枚举、ReadingTimerDeepLinkRequest 与 scene 级 newest-wins 路由器
 * [POS]: Navigation 模块的在读浏览路由和外部计时意图边界，避免全屏计时目标进入持久化返回栈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// ReadingRoute 定义主导航的导航目标与路由参数。
enum ReadingRoute: Hashable, Codable {
    case bookDetail(bookId: Int64)
    case readingSupplement(bookId: Int64)
}

/// 外部计时意图只描述最终全屏目标，不属于任何 Tab 的浏览历史。
enum ReadingTimerDeepLinkRequest: Hashable {
    case book(bookId: Int64)
    case record(recordId: Int64, bookId: Int64)
}

/// 阅读计时深链分发器，将 App 根层收到的 URL 转成 MainTabView 可消费的精确计时路由。
@Observable
final class ReadingTimerDeepLinkRouter {
    var pendingRequest: ReadingTimerDeepLinkRequest?

    /// 解析阅读计时深链；返回值表示 URL 是否已由本路由消费。
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "xmnote", url.host == "reading-timer" else {
            return false
        }
        let rawBookId = url.pathComponents.dropFirst().first ?? ""
        guard let bookId = Int64(rawBookId), bookId > 0 else {
            return false
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let recordId = components?.queryItems?
            .first(where: { $0.name == "recordId" })?
            .value
            .flatMap(Int64.init)
        if let recordId, recordId > 0 {
            pendingRequest = .record(recordId: recordId, bookId: bookId)
        } else {
            pendingRequest = .book(bookId: bookId)
        }
        return true
    }

    /// 清除已完成导航的请求，避免视图恢复时重复打开同一计时记录。
    func consume(_ request: ReadingTimerDeepLinkRequest) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
    }
}
