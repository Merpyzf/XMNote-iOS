/**
 * [INPUT]: 依赖 SwiftUI NavigationPath、AppTab、各业务编辑/查看/导入路由参数与阅读日历初始日期
 * [OUTPUT]: 对外提供 AppNavigationCoordinator、AppFullScreenTaskDestination、浏览回流目标与沉浸页 Tab chrome 抑制票据
 * [POS]: Navigation 模块的根级沉浸内容与任务呈现协调器，统一隔离可恢复浏览路径与临时全屏路径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftUI

/// 全屏任务中的导航层级，决定根任务使用取消/关闭，子步骤使用返回。
enum AppTaskNavigationContext: Hashable {
    case modalRoot
    case taskChild
}

/// 数据导入目录选择后的独立任务目标；目录本身仍属于“我的”Tab 浏览路径。
enum DataImportTaskDestination: Hashable {
    case desktopComputer
    case lifeWeek
    case wereadAuthorization
    case api
    case hanwang
    case file(title: String, parserID: NoteImportParserID?)
    case fileCandidates(title: String, parserIDs: [NoteImportParserID])
    case clipboard(title: String, parserID: NoteImportParserID)
    case clipboardCandidates(title: String, parserIDs: [NoteImportParserID])
}

/// 不参与 scene 恢复的全屏内容与任务目标；所有目标由 MainTabView 的单一 cover 呈现。
enum AppFullScreenTaskDestination: Hashable {
    case addBook
    case bookEditor(BookEditorMode)
    case noteEditor(mode: NoteEditorMode, seed: NoteEditorSeed?)
    case reviewEditor(ReviewEditorMode)
    case relevantEditor(RelevantEditorMode)
    case contentViewer(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        keyword: String
    )
    case readCalendar(initialDate: Date?)
    case readingSession(bookID: UUID)
    case dataImport(DataImportTaskDestination)
}

/// 退出全屏任务后需要在来源 Tab 继续打开的普通浏览目标。
enum AppBrowseDestination: Hashable {
    case book(BookRoute)
    case note(NoteRoute)
    case content(ContentRoute)
    case personal(PersonalRoute)
    case reading(ReadingRoute)
}

/// 根级全屏呈现项，同时记录来路 Tab，确保关闭后恢复原有现场。
struct AppFullScreenTaskPresentation: Identifiable, Hashable {
    let id: UUID
    let destination: AppFullScreenTaskDestination
    let originTab: AppTab

    init(destination: AppFullScreenTaskDestination, originTab: AppTab) {
        id = UUID()
        self.destination = destination
        self.originTab = originTab
    }
}

/// 全屏任务关闭后等待 MainTabView 消费的普通浏览回流请求。
struct PendingBrowseNavigation: Hashable {
    let tab: AppTab
    let destination: AppBrowseDestination
}

/// 根级导航协调器，管理低频全屏任务、浏览回流与沉浸页对根 Tab chrome 的成对抑制票据。
@MainActor
@Observable
final class AppNavigationCoordinator {
    var activeTask: AppFullScreenTaskPresentation?
    var taskPath = NavigationPath()

    private(set) var currentTab: AppTab = .reading
    private var pendingBrowseNavigation: PendingBrowseNavigation?
    private var addBookCompletion: ((BookPickerBook) -> Void)?
    private var bookEditorCompletion: ((Int64) -> Void)?
    private var tabChromeSuppressionTokens: Set<UUID> = []

    /// 只要任一可见沉浸页仍持有票据，根 Tab Bar 与底部附件就保持收起。
    var isTabChromeSuppressed: Bool {
        !tabChromeSuppressionTokens.isEmpty
    }

    /// 登记沉浸页票据；使用集合去重，避免重复 appear 导致无法恢复根 Tab chrome。
    func suppressTabChrome(for token: UUID) {
        tabChromeSuppressionTokens.insert(token)
    }

    /// 释放离场页面票据；多层导航交叠期间其他页面票据仍可继续维持沉浸状态。
    func restoreTabChrome(for token: UUID) {
        tabChromeSuppressionTokens.remove(token)
    }

    /// 同步当前顶层 Tab，供新的全屏任务记录准确来路。
    func updateCurrentTab(_ tab: AppTab) {
        currentTab = tab
    }

    /// 打开全屏内容或任务；若已经处于全屏任务中，则沿用当前任务栈继续深入，避免叠加模态。
    func present(_ destination: AppFullScreenTaskDestination) {
        switch destination {
        case .addBook:
            addBookCompletion = nil
        case .bookEditor:
            bookEditorCompletion = nil
        default:
            break
        }

        if activeTask != nil {
            taskPath.append(destination)
            return
        }

        taskPath = NavigationPath()
        activeTask = AppFullScreenTaskPresentation(
            destination: destination,
            originTab: currentTab
        )
    }

    /// 打开新增书籍任务，并在保存入库后将完整书籍回填给发起页面。
    func presentAddBook(onCompleted: ((BookPickerBook) -> Void)? = nil) {
        present(.addBook)
        addBookCompletion = onCompleted
    }

    /// 打开书籍编辑任务，并在保存后把书籍 ID 回填给发起页面。
    func presentBookEditor(
        mode: BookEditorMode,
        onSaved: ((Int64) -> Void)? = nil
    ) {
        present(.bookEditor(mode))
        bookEditorCompletion = onSaved
    }

    /// 收口新增书籍结果；根任务关闭 cover，任务子步骤只返回上一层编辑现场。
    func completeAddBook(_ book: BookPickerBook) {
        let completion = addBookCompletion
        addBookCompletion = nil
        completion?(book)

        if taskPath.isEmpty {
            dismissTask()
        } else {
            taskPath.removeLast()
        }
    }

    /// 将书籍保存结果回填给任务发起页面；页面自身负责按当前导航层级关闭或返回。
    func completeBookEditor(_ bookID: Int64) {
        let completion = bookEditorCompletion
        bookEditorCompletion = nil
        completion?(bookID)
    }

    /// 关闭整个全屏任务并保留底层 Tab 现场。
    func dismissTask() {
        activeTask = nil
    }

    /// 关闭任务后回到普通浏览层级；默认在任务的来源 Tab 上继续导航。
    func exitTask(
        to destination: AppBrowseDestination,
        targetTab: AppTab? = nil
    ) {
        let originTab = activeTask?.originTab ?? currentTab
        pendingBrowseNavigation = PendingBrowseNavigation(
            tab: targetTab ?? originTab,
            destination: destination
        )
        activeTask = nil
    }

    /// 完成系统 cover 退场后的状态清理，并返回一次性浏览回流请求。
    func completeTaskDismissal() -> PendingBrowseNavigation? {
        taskPath = NavigationPath()
        activeTask = nil
        addBookCompletion = nil
        bookEditorCompletion = nil
        defer { pendingBrowseNavigation = nil }
        return pendingBrowseNavigation
    }
}
