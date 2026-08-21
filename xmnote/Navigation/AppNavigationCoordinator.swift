/**
 * [INPUT]: 依赖 SwiftUI Binding、AppRoute/AppTaskRoute、AppSceneSnapshot、各业务编辑/查看/导入参数与阅读日历初始日期
 * [OUTPUT]: 对外提供 AppNavigationCoordinator、AppFullScreenTaskDestination、五个受控浏览栈、一次性浏览回流与 Tab chrome 抑制票据
 * [POS]: Navigation 模块的 scene 级唯一导航 owner，统一约束浏览 push/pop、深链替换与临时全屏任务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import OSLog
import SwiftUI

/// 全屏任务中的导航层级，决定根任务使用取消/关闭，子步骤使用返回。
enum AppTaskNavigationContext: Hashable {
    case modalRoot
    case taskChild
}

/// 书摘导入目录选择后的独立任务目标；目录本身仍属于“我的”Tab 浏览路径。
enum DataImportTaskDestination: Hashable {
    case desktopComputer
    case lifeWeek
    case wereadAuthorization
    case kindle
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
    case dataImport(DataImportTaskDestination)
}

typealias AppBrowseDestination = AppRoute

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
    static let maximumBrowseDepth = 32

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "XMNote",
        category: "Navigation"
    )

    private(set) var activeTask: AppFullScreenTaskPresentation?
    private(set) var isTaskDismissalInFlight = false
    var taskPath: [AppTaskRoute] = []
    var selectedTab: AppTab
    private(set) var browseNavigation: NavigationSceneSnapshot

    private var pendingBrowseNavigation: PendingBrowseNavigation?
    private var addBookCompletion: ((BookPickerBook) -> Void)?
    private var bookEditorCompletion: ((Int64) -> Void)?
    private var tabChromeSuppressionTokens: [UUID: AppTab] = [:]

    /// 只要任一可见沉浸页仍持有票据，根 Tab Bar 与底部附件就保持收起。
    var isTabChromeSuppressed: Bool {
        tabChromeSuppressionTokens.values.contains(selectedTab) || currentBrowseBranchIsImmersive
    }

    /// 路径中一旦进入沉浸式书籍工作区，其所有后续子页都继承隐藏语义，直到返回该分支之前。
    private var currentBrowseBranchIsImmersive: Bool {
        path(for: selectedTab).contains(where: \.establishesImmersiveBrowseBranch)
    }

    /// 当前可持久化浏览状态；全屏任务与任务内路径永远不包含在内。
    var browseState: AppBrowseNavigationState {
        AppBrowseNavigationState(
            selectedTab: selectedTab,
            navigation: browseNavigation
        )
    }

    /// 全屏任务从挂载到系统确认退场前始终占用呈现通道，避免新任务或计时页穿插进退场动画。
    var isTaskPresentationActiveOrDismissing: Bool {
        activeTask != nil || isTaskDismissalInFlight
    }

    init() {
        selectedTab = .reading
        browseNavigation = NavigationSceneSnapshot()
    }

    init(snapshot: AppSceneSnapshot) {
        selectedTab = snapshot.selectedTab
        browseNavigation = snapshot.navigation.sanitized()
    }

    /// 登记沉浸页票据并绑定当前 Tab，避免重复 appear 或后台 Tab 污染当前页面 chrome。
    func suppressTabChrome(for token: UUID) {
        tabChromeSuppressionTokens[token] = selectedTab
    }

    /// 释放离场页面票据；多层导航交叠期间其他页面票据仍可继续维持沉浸状态。
    func restoreTabChrome(for token: UUID) {
        tabChromeSuppressionTokens.removeValue(forKey: token)
    }

    /// 同步当前顶层 Tab；保留该入口以兼容页面事件，实际 owner 始终是 selectedTab。
    func updateCurrentTab(_ tab: AppTab) {
        selectedTab = tab
    }

    /// 返回受控路径绑定；系统返回手势提交的缩短路径会被接受，异常增长仍统一净化。
    func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { [weak self] in self?.path(for: tab) ?? [] },
            set: { [weak self] path in self?.acceptSystemPath(path, for: tab) }
        )
    }

    /// 受控 cover 绑定捕获系统或子页面触发的 dismiss 写入，直到 onDismiss 才释放呈现通道。
    var taskPresentationBinding: Binding<AppFullScreenTaskPresentation?> {
        Binding(
            get: { [weak self] in self?.activeTask },
            set: { [weak self] presentation in
                guard let self else { return }
                if presentation == nil, self.activeTask != nil {
                    self.isTaskDismissalInFlight = true
                }
                self.activeTask = presentation
            }
        )
    }

    /// 读取指定 Tab 当前浏览路径。
    func path(for tab: AppTab) -> [AppRoute] {
        browseNavigation.path(for: tab)
    }

    /// 在指定 Tab 内打开浏览目标：顶部重复忽略、已有目标回退到旧位置，否则正常 push。
    func push(_ route: AppRoute, in tab: AppTab? = nil) {
        let targetTab = tab ?? selectedTab
        var path = path(for: targetTab)
        guard route.isPersistableBrowseRoute else {
            Self.logger.error("Rejected task route from browse stack tab=\(targetTab.rawValue, privacy: .public)")
            return
        }
        if path.last == route { return }
        if let existingIndex = path.firstIndex(of: route) {
            path.removeSubrange(path.index(after: existingIndex)..<path.endIndex)
        } else {
            path.append(route)
        }
        setBrowsePath(path, for: targetTab, reason: "push")
    }

    /// 深链导航切换目标 Tab 并替换其历史，不把外部意图附加到用户旧浏览链。
    func replacePath(for tab: AppTab, with path: [AppRoute]) {
        selectedTab = tab
        setBrowsePath(path, for: tab, reason: "deep-link")
    }

    /// 只回退指定 Tab 的顶部浏览目标。
    func pop(in tab: AppTab? = nil) {
        let targetTab = tab ?? selectedTab
        var path = path(for: targetTab)
        guard !path.isEmpty else { return }
        path.removeLast()
        setBrowsePath(path, for: targetTab, reason: "programmatic-pop")
    }

    /// 打开全屏内容或任务；若已经处于全屏任务中，则沿用当前任务栈继续深入，避免叠加模态。
    @discardableResult
    func present(_ destination: AppFullScreenTaskDestination) -> Bool {
        switch destination {
        case .addBook:
            addBookCompletion = nil
        case .bookEditor:
            bookEditorCompletion = nil
        default:
            break
        }

        if activeTask != nil {
            taskPath.append(.destination(destination))
            return true
        }

        guard !isTaskDismissalInFlight else {
            Self.logger.warning("Rejected task presentation while previous cover is dismissing")
            return false
        }

        taskPath = []
        activeTask = AppFullScreenTaskPresentation(
            destination: destination,
            originTab: selectedTab
        )
        return true
    }

    /// 打开新增书籍任务，并在保存入库后将完整书籍回填给发起页面。
    func presentAddBook(onCompleted: ((BookPickerBook) -> Void)? = nil) {
        if present(.addBook) {
            addBookCompletion = onCompleted
        }
    }

    /// 打开书籍编辑任务，并在保存后把书籍 ID 回填给发起页面。
    func presentBookEditor(
        mode: BookEditorMode,
        onSaved: ((Int64) -> Void)? = nil
    ) {
        if present(.bookEditor(mode)) {
            bookEditorCompletion = onSaved
        }
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
        guard activeTask != nil else { return }
        isTaskDismissalInFlight = true
        activeTask = nil
    }

    /// 关闭任务后回到普通浏览层级；默认在任务的来源 Tab 上继续导航。
    func exitTask(
        to destination: AppBrowseDestination,
        targetTab: AppTab? = nil
    ) {
        let originTab = activeTask?.originTab ?? selectedTab
        pendingBrowseNavigation = PendingBrowseNavigation(
            tab: targetTab ?? originTab,
            destination: destination
        )
        isTaskDismissalInFlight = isTaskPresentationActiveOrDismissing
        activeTask = nil
    }

    /// 完成系统 cover 退场后的状态清理，并返回一次性浏览回流请求。
    func completeTaskDismissal() -> PendingBrowseNavigation? {
        taskPath = []
        activeTask = nil
        isTaskDismissalInFlight = false
        addBookCompletion = nil
        bookEditorCompletion = nil
        defer { pendingBrowseNavigation = nil }
        return pendingBrowseNavigation
    }

    /// 系统导航提交优先接受缩短路径；增长路径也走同一净化器，防止未受控 Link 制造循环或超深栈。
    private func acceptSystemPath(_ path: [AppRoute], for tab: AppTab) {
        let current = self.path(for: tab)
        if path.count <= current.count, current.starts(with: path) {
            browseNavigation.setPath(path, for: tab)
            return
        }
        setBrowsePath(path, for: tab, reason: "system")
    }

    private func setBrowsePath(_ path: [AppRoute], for tab: AppTab, reason: String) {
        let sanitized = AppRoute.sanitizedBrowsePath(
            path,
            maximumDepth: Self.maximumBrowseDepth
        )
        if sanitized != path {
            Self.logger.warning(
                "Sanitized browse path tab=\(tab.rawValue, privacy: .public) reason=\(reason, privacy: .public) input=\(path.count) kept=\(sanitized.count)"
            )
        }
        browseNavigation.setPath(sanitized, for: tab)
    }

}
