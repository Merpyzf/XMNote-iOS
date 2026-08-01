/**
 * [INPUT]: 依赖 Foundation（Date/URL）与 Observation，解析 App 根层接收的阅读计时深链
 * [OUTPUT]: 对外提供 ReadingRoute 枚举与 ReadingTimerDeepLinkRouter，定义在读模块可恢复的书籍详情、计时与阅读日历目的地
 * [POS]: Navigation 模块的在读路由，被 xmnoteApp、ReadingContainerView 与 MainTabView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// ReadingRoute 定义主导航的导航目标与路由参数。
enum ReadingRoute: Hashable, Codable {
    case bookDetail(bookId: Int64)
    case readingSession(bookId: Int64)
    case readingSessionRecord(recordId: Int64, bookId: Int64)
    case readingSupplement(bookId: Int64)
    case readCalendar(date: Date?)
}

/// 阅读计时深链分发器，将 App 根层收到的 URL 转成 MainTabView 可消费的精确计时路由。
@Observable
final class ReadingTimerDeepLinkRouter {
    var pendingRoute: ReadingRoute?

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
            pendingRoute = .readingSessionRecord(recordId: recordId, bookId: bookId)
        } else {
            pendingRoute = .readingSession(bookId: bookId)
        }
        return true
    }

    /// 清除已完成导航的请求，避免视图恢复时重复打开同一计时记录。
    func consume(_ route: ReadingRoute) {
        guard pendingRoute == route else { return }
        pendingRoute = nil
    }
}
