/**
 * [INPUT]: 依赖五个主 Tab 及各业务模块中仅表达可返回浏览页面的 Codable 路由，包括不保存运行态的导出路由
 * [OUTPUT]: 对外提供 AppRoute、AppTaskRoute、NavigationSceneSnapshot 路径净化与原子浏览状态
 * [POS]: Navigation 模块的类型安全路由边界，隔离可持久化浏览栈与一次性全屏任务栈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 应用主 Tab 身份；每个 scene 为五个 Tab 分别持有独立浏览栈。
enum AppTab: String, CaseIterable, Codable {
    case reading, books, notes, profile, search
}

/// 可返回、可检查且可跨启动恢复的统一浏览路由。
enum AppRoute: Hashable, Codable {
    case book(BookRoute)
    case reading(ReadingRoute)
    case note(NoteRoute)
    case content(ContentRoute)
    case personal(PersonalRoute)
    case export(ExportRoute)
    case debug(DebugRoute)

    /// 浏览枚举已经在类型层排除任务目标，因此成功解码的统一路由都可持久化。
    var isPersistableBrowseRoute: Bool {
        true
    }

    /// 进入沉浸式书籍工作区后由路径语义持续隐藏根 Tab chrome；后续子页无需依赖父页生命周期接力。
    var establishesImmersiveBrowseBranch: Bool {
        guard case let .book(route) = self else { return false }
        switch route {
        case .detail, .chapterCatalog, .readingDetail, .chapterManager, .chapterNotes:
            return true
        case .bookshelfList, .collectionDetail:
            return false
        }
    }

    /// 依次校验、去重、去环并限制深度；非法目标会截断其后内容，避免恢复半条错误历史。
    static func sanitizedBrowsePath(
        _ path: [AppRoute],
        maximumDepth: Int = 32
    ) -> [AppRoute] {
        guard maximumDepth > 0 else { return [] }

        var result: [AppRoute] = []
        result.reserveCapacity(min(path.count, maximumDepth))

        for route in path {
            guard route.isPersistableBrowseRoute else { break }
            if result.last == route {
                continue
            }
            if let existingIndex = result.firstIndex(of: route) {
                result.removeSubrange(result.index(after: existingIndex)..<result.endIndex)
                continue
            }
            guard result.count < maximumDepth else { break }
            result.append(route)
        }
        return result
    }
}

/// 只存在于当前全屏任务生命周期内的二级路径，不参与 scene 持久化。
enum AppTaskRoute: Hashable {
    case destination(AppFullScreenTaskDestination)
    case book(BookRoute)
    case reading(ReadingRoute)
    case note(NoteRoute)
    case content(ContentRoute)
    case readCalendar(ReadCalendarRoute)
}

/// 单个 scene 的完整浏览状态，用于协调器变化监听和一次性原子持久化。
struct AppBrowseNavigationState: Hashable, Codable {
    var selectedTab: AppTab
    var navigation: NavigationSceneSnapshot
}
