#if DEBUG
/**
 * [INPUT]: 依赖 Foundation、Observation、仓库内 90 个既有 Sheet 调用点、113 个生产目标与 Android a4aef673293f 只读事实快照
 * [OUTPUT]: 对外提供 SheetCatalogTestViewModel、九类历史结构索引、用途/类比事实、113 个生产预览定义与逐目标展示请求
 * [POS]: Debug 测试中心 Sheet 样式校准页的目录状态 owner，数据快照由 Repository 层独立负责
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

enum SheetCatalogOrigin: String, CaseIterable, Hashable, Identifiable {
    case production = "生产调用"
    case debug = "Debug 实验"

    var id: Self { self }
}

enum SheetCatalogPresentationKind: String, Hashable {
    case isPresented = ".sheet(isPresented:)"
    case item = ".sheet(item:)"
}

enum SheetCatalogFamily: String, CaseIterable, Hashable, Identifiable {
    case scaffoldClose = "scaffold-close"
    case scaffoldPairedActions = "scaffold-paired-actions"
    case scaffoldBottomAction = "scaffold-bottom-action"
    case scaffoldTopControl = "scaffold-top-control"
    case scaffoldTopAndBottom = "scaffold-top-bottom"
    case scaffoldDynamicSubtitle = "scaffold-dynamic-subtitle"
    case nativeToolbar = "native-toolbar"
    case customBusinessShell = "custom-business-shell"
    case systemControllerBridge = "system-controller-bridge"

    var id: String { rawValue }

    var index: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 0
    }

    var title: String {
        switch self {
        case .scaffoldClose:
            "XMSheetScaffold 基础关闭"
        case .scaffoldPairedActions:
            "XMSheetScaffold 顶部成对操作"
        case .scaffoldBottomAction:
            "XMSheetScaffold 固定底部操作"
        case .scaffoldTopControl:
            "XMSheetScaffold 固定顶部控件"
        case .scaffoldTopAndBottom:
            "XMSheetScaffold 固定顶部与底部操作"
        case .scaffoldDynamicSubtitle:
            "XMSheetScaffold 动态副标题、顶部与底部"
        case .nativeToolbar:
            "原生 NavigationStack + Toolbar"
        case .customBusinessShell:
            "自定义业务壳层"
        case .systemControllerBridge:
            "系统控制器桥接"
        }
    }

    var shortTitle: String {
        switch self {
        case .scaffoldClose: "基础关闭"
        case .scaffoldPairedActions: "顶部成对操作"
        case .scaffoldBottomAction: "固定底部操作"
        case .scaffoldTopControl: "固定顶部控件"
        case .scaffoldTopAndBottom: "顶部与底部"
        case .scaffoldDynamicSubtitle: "动态复合结构"
        case .nativeToolbar: "原生工具栏"
        case .customBusinessShell: "自定义壳层"
        case .systemControllerBridge: "系统控制器"
        }
    }

    var summary: String {
        switch self {
        case .scaffoldClose:
            "标准标题与单一关闭动作，内容独立滚动。"
        case .scaffoldPairedActions:
            "标题两侧承载取消与确认等同级操作。"
        case .scaffoldBottomAction:
            "顶部负责退出，底部固定主要提交操作。"
        case .scaffoldTopControl:
            "搜索或筛选固定在内容区顶部。"
        case .scaffoldTopAndBottom:
            "固定顶部控件与底部提交共同围合滚动内容。"
        case .scaffoldDynamicSubtitle:
            "标题下动态摘要，并同时使用顶部控件与底部操作。"
        case .nativeToolbar:
            "使用系统导航栈及 Toolbar placement 组织模态操作。"
        case .customBusinessShell:
            "业务页面自行组合标题、内容与操作位置。"
        case .systemControllerBridge:
            "SwiftUI Sheet 承载 UIKit 分享或文档选择控制器。"
        }
    }

    var systemImage: String {
        switch self {
        case .scaffoldClose: "xmark.circle"
        case .scaffoldPairedActions: "arrow.left.arrow.right"
        case .scaffoldBottomAction: "rectangle.bottomthird.inset.filled"
        case .scaffoldTopControl: "rectangle.topthird.inset.filled"
        case .scaffoldTopAndBottom: "rectangle.portrait"
        case .scaffoldDynamicSubtitle: "text.alignleft"
        case .nativeToolbar: "list.bullet.rectangle"
        case .customBusinessShell: "square.dashed"
        case .systemControllerBridge: "square.and.arrow.up"
        }
    }

    var appleCalibrationGuidance: String {
        switch self {
        case .scaffoldClose:
            "即时生效或只读任务仅保留左侧关闭，不增加伪确认，也不显示无意义搜索。"
        case .scaffoldPairedActions:
            "独立草稿使用左侧关闭与右侧确认；确认期间原位显示进度并锁定退出。"
        case .scaffoldBottomAction:
            "普通单页提交上移到右侧保存；只有确需常驻错误或复杂进度的长任务才保留底部操作区。"
        case .scaffoldTopControl:
            "左侧关闭，下方使用系统搜索；筛选或即时选择不额外显示确认。"
        case .scaffoldTopAndBottom:
            "搜索保留在系统工具栏下方，底部确认上移到右侧；滚动内容使用系统 soft edge。"
        case .scaffoldDynamicSubtitle:
            "选择数量降为搜索下方辅助信息，确认上移到右侧，不把动态摘要塞进导航标题。"
        case .nativeToolbar:
            "继续使用 NavigationStack，并统一 cancellationAction、confirmationAction 与内联标题语义。"
        case .customBusinessShell:
            "移除自造标题栏和重复材质，按任务语义回归系统导航工具栏与系统搜索。"
        case .systemControllerBridge:
            "由系统分享或文档控制器完整持有外观与操作，不在外层安装业务工具栏。"
        }
    }
}

struct SheetCatalogPresentationFacts: Hashable {
    let detents: String
    let dragIndicator: String
    let background: String
    let backgroundInteraction: String
    let contentInteraction: String
    let actionPlacement: String
    let interactiveDismissal: String

    static func defaults(for family: SheetCatalogFamily) -> Self {
        let actionPlacement: String
        switch family {
        case .scaffoldClose:
            actionPlacement = "标题栏尾随侧关闭"
        case .scaffoldPairedActions:
            actionPlacement = "标题栏前导与尾随成对操作"
        case .scaffoldBottomAction:
            actionPlacement = "标题栏关闭 + 固定底部操作"
        case .scaffoldTopControl:
            actionPlacement = "标题栏关闭 + 固定内容顶部控件"
        case .scaffoldTopAndBottom:
            actionPlacement = "标题栏关闭 + 固定顶部控件 + 固定底部操作"
        case .scaffoldDynamicSubtitle:
            actionPlacement = "动态标题摘要 + 固定顶部控件 + 固定底部操作"
        case .nativeToolbar:
            actionPlacement = "NavigationStack Toolbar，由目标声明 placement"
        case .customBusinessShell:
            actionPlacement = "由业务壳层自行声明"
        case .systemControllerBridge:
            actionPlacement = "由 UIKit 系统控制器管理"
        }

        return Self(
            detents: "调用点未显式覆盖；由目标 owner 或系统默认值决定",
            dragIndicator: "调用点未显式覆盖；由目标 owner 或系统默认值决定",
            background: "调用点未显式覆盖；由目标 owner 或系统默认值决定",
            backgroundInteraction: "未显式设置（系统默认）",
            contentInteraction: "未显式设置（系统默认）",
            actionPlacement: actionPlacement,
            interactiveDismissal: "调用点未显式锁定；目标内部可能按写入状态锁定"
        )
    }

    static func mediumLarge(
        family: SheetCatalogFamily,
        background: String = "未显式设置（系统默认）",
        backgroundInteraction: String = "未显式设置（系统默认）",
        contentInteraction: String = "未显式设置（系统默认）",
        interactiveDismissal: String? = nil
    ) -> Self {
        let base = defaults(for: family)
        return Self(
            detents: ".medium / .large",
            dragIndicator: ".visible",
            background: background,
            backgroundInteraction: backgroundInteraction,
            contentInteraction: contentInteraction,
            actionPlacement: base.actionPlacement,
            interactiveDismissal: interactiveDismissal ?? base.interactiveDismissal
        )
    }
}

struct SheetCatalogTarget: Identifiable, Hashable {
    let id: String
    let owner: String
    let sheetPurpose: String
    let androidAnalogue: SheetCatalogAndroidAnalogue
    let facts: SheetCatalogPresentationFacts
    let productionPreview: SheetProductionPreviewDefinition?
}

enum SheetProductionPreviewDataRequirement: String, Hashable {
    case none
    case books
    case notes
    case tags
    case collections
    case reading
    case safeExternal

    var title: String {
        switch self {
        case .none: "不依赖业务实体"
        case .books: "书籍与书架上下文"
        case .notes: "书摘、想法与编辑上下文"
        case .tags: "标签与选择上下文"
        case .collections: "书单与书籍上下文"
        case .reading: "阅读记录、目标与日期上下文"
        case .safeExternal: "生产输入 + 安全外部模拟"
        }
    }
}

enum SheetProductionPreviewDataMode: String, Hashable {
    case productionSnapshot = "实际生产快照"
    case snapshotWithFixture = "实际快照 + 补充夹具"
    case safeExternalSimulation = "安全外部模拟"
}

struct SheetProductionPreviewDefinition: Hashable {
    let targetID: String
    let rendererOwner: String
    let dataRequirement: SheetProductionPreviewDataRequirement
    let dataSource: String
    let productionConfiguration: String
    let currentStructure: String

    func dataMode(for snapshot: SheetPreviewSnapshot) -> SheetProductionPreviewDataMode {
        if dataRequirement == .safeExternal {
            return .safeExternalSimulation
        }
        return hasRequiredData(in: snapshot)
            ? .productionSnapshot
            : .snapshotWithFixture
    }

    func actualDataDescription(in snapshot: SheetPreviewSnapshot) -> String {
        switch dataRequirement {
        case .none:
            return "使用当前生产配置和空草稿；不读取敏感信息"
        case .books:
            let titles = snapshot.representativeBooks.prefix(3).map(\.title)
            return titles.isEmpty
                ? "生产快照暂无有效书籍；打开时补充 1 本最小合法书籍"
                : "\(snapshot.counts.books) 本书；当前样例：\(titles.joined(separator: "、"))"
        case .notes:
            let excerpt = snapshot.representativeNoteText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(24)
            return excerpt.map {
                "\(snapshot.counts.notes) 条书摘/想法；当前内容：\($0)"
            } ?? "生产快照暂无非空书摘；打开时使用最小合法内容夹具"
        case .tags:
            let names = snapshot.representativeTags.prefix(3).map(\.title)
            return names.isEmpty
                ? "生产快照暂无标签；打开时使用最小合法标签夹具"
                : "\(snapshot.counts.tags) 个标签；当前样例：\(names.joined(separator: "、"))"
        case .collections:
            let names = snapshot.representativeCollections.prefix(3).map(\.title)
            return names.isEmpty
                ? "生产快照暂无书单；打开时使用最小合法书单夹具"
                : "\(snapshot.counts.collections) 个书单；当前样例：\(names.joined(separator: "、"))"
        case .reading:
            return "\(snapshot.counts.readingRecords) 条阅读记录；可用书籍 \(snapshot.counts.books) 本"
        case .safeExternal:
            return "输入来自生产快照（\(snapshot.counts.books) 本书 / \(snapshot.counts.notes) 条内容）；外部响应已脱敏并替换"
        }
    }

    var requiresFixtureFallback: Bool {
        switch dataRequirement {
        case .books, .notes, .tags, .collections, .reading:
            true
        case .none, .safeExternal:
            false
        }
    }

    private func hasRequiredData(in snapshot: SheetPreviewSnapshot) -> Bool {
        switch dataRequirement {
        case .none, .safeExternal:
            true
        case .books:
            snapshot.counts.books > 0
        case .notes:
            snapshot.counts.notes > 0
        case .tags:
            snapshot.counts.tags > 0
        case .collections:
            snapshot.counts.collections > 0
        case .reading:
            snapshot.counts.readingRecords > 0
        }
    }
}

enum SheetCatalogAndroidReferenceRole: String, Hashable {
    case launchEntry = "启动入口"
    case targetOwner = "目标组件"
}

struct SheetCatalogAndroidReference: Hashable {
    let role: SheetCatalogAndroidReferenceRole
    let owner: String
    let sourcePath: String
    let sourceLine: Int

    var sourceLocation: String {
        "\(sourcePath):\(sourceLine)"
    }
}

struct SheetCatalogAndroidAnalogue: Hashable {
    let scene: String
    let references: [SheetCatalogAndroidReference]

    var searchableText: String {
        ([scene] + references.flatMap { [$0.role.rawValue, $0.owner, $0.sourcePath] })
            .joined(separator: " ")
    }
}

struct SheetCatalogCallSite: Identifiable, Hashable {
    let id: String
    let origin: SheetCatalogOrigin
    let module: String
    let host: String
    let appPurpose: String
    let sourcePath: String
    let sourceLine: Int
    let presentationKind: SheetCatalogPresentationKind
    let family: SheetCatalogFamily
    let isNested: Bool
    let targets: [SheetCatalogTarget]

    var sourceLocation: String {
        "\(sourcePath):\(sourceLine)"
    }

    var searchableText: String {
        ([module, host, appPurpose, sourcePath, presentationKind.rawValue, family.title]
            + targets.flatMap {
                [
                    $0.owner,
                    $0.sheetPurpose,
                    $0.androidAnalogue.searchableText,
                    $0.productionPreview?.dataSource ?? "",
                    $0.productionPreview?.currentStructure ?? ""
                ]
            })
            .joined(separator: " ")
    }
}

struct SheetCatalogFamilySummary: Identifiable, Hashable {
    let family: SheetCatalogFamily
    let productionCount: Int
    let debugCount: Int
    let targetOwnerCount: Int

    var id: SheetCatalogFamily { family }
    var totalCount: Int { productionCount + debugCount }
}

struct SheetCatalogPreviewRequest: Identifiable, Hashable {
    let target: SheetCatalogTarget

    var id: String { target.id }
}

enum SheetCatalogSnapshotPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class SheetCatalogSnapshotController {
    var phase: SheetCatalogSnapshotPhase = .idle
    var snapshot: SheetPreviewSnapshot?

    private let repository: SheetPreviewSnapshotRepository
    private var activeWorkspace: SheetPreviewWorkspace?

    init(databaseManager: DatabaseManager) {
        repository = SheetPreviewSnapshotRepository(sourceDatabaseManager: databaseManager)
    }

    isolated deinit {
        activeWorkspace?.destroy()
        repository.destroyBaseDatabase()
    }

    /// 刷新目录的生产基础快照；取消时不覆盖上一份可用快照。
    func refresh() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let snapshot = try await repository.refreshSnapshot()
            try Task.checkCancellation()
            self.snapshot = snapshot
            phase = .loaded
        } catch is CancellationError {
            phase = snapshot == nil ? .idle : .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 从基础快照创建本次目标专属工作副本；新副本创建前释放上一次副本。
    func makeWorkspace(for target: SheetCatalogTarget) async throws -> SheetPreviewWorkspace {
        releaseActiveWorkspace()
        guard let definition = target.productionPreview else {
            throw SheetPreviewSnapshotError.snapshotUnavailable
        }
        let workspace = try await repository.makeWorkspace(
            requiresFixtureFallback: definition.requiresFixtureFallback
        )
        activeWorkspace = workspace
        return workspace
    }

    /// Sheet 关闭时销毁本次数据库与偏好副本，确保下次打开恢复相同基础数据。
    func releaseActiveWorkspace() {
        activeWorkspace?.destroy()
        activeWorkspace = nil
    }
}

@MainActor
@Observable
final class SheetCatalogTestViewModel {
    static let androidBaseline = "master@a4aef673293f"

    var searchText = ""
    var presentedPreview: SheetCatalogPreviewRequest?

    let callSites: [SheetCatalogCallSite]

    init() {
        let callSites = SheetCatalogManifest.callSites
        self.callSites = callSites
        assert(callSites.count == 90, "Sheet 校准基线必须保持 90 个既有调用点")
        assert(Set(callSites.map(\.id)).count == callSites.count, "Sheet 清单业务 ID 不得重复")
        assert(callSites.allSatisfy { !$0.targets.isEmpty }, "每个 Sheet 调用点至少需要一个目标分支")
        let targets = callSites.flatMap(\.targets)
        assert(targets.count == 122, "Sheet 校准基线必须保持 122 个目标分支")
        assert(Set(targets.map(\.id)).count == targets.count, "Sheet 目标分支 ID 不得重复")
        let productionTargets = callSites
            .filter { $0.origin == .production }
            .flatMap(\.targets)
        let debugTargets = callSites
            .filter { $0.origin == .debug }
            .flatMap(\.targets)
        assert(productionTargets.count == 113, "生产 Sheet 必须保持 113 个目标分支")
        assert(debugTargets.count == 9, "Debug Sheet 必须保持 9 个目标分支")
        assert(
            productionTargets.allSatisfy { $0.productionPreview != nil },
            "113 个生产目标必须全部具有可执行预览定义"
        )
        assert(
            productionTargets.allSatisfy(SheetProductionValidationTestView.supportsProductionTarget),
            "113 个生产目标必须全部解析到具体生产 View renderer"
        )
        assert(
            debugTargets.allSatisfy { $0.productionPreview == nil },
            "Debug 实验不得混入生产预览统计"
        )
        assert(
            Set(productionTargets.map(\.owner)).count == 77,
            "生产目录必须保持 77 种实际目标结构"
        )
        assert(callSites.allSatisfy { !$0.appPurpose.isEmpty }, "每个 Sheet 调用点必须说明 App 用途")
        assert(targets.allSatisfy { !$0.sheetPurpose.isEmpty }, "每个 Sheet 目标分支必须说明用途")
        assert(
            targets.allSatisfy {
                !$0.androidAnalogue.scene.isEmpty
                    && !$0.androidAnalogue.references.isEmpty
                    && $0.androidAnalogue.references.allSatisfy {
                        !$0.owner.isEmpty && !$0.sourcePath.isEmpty && $0.sourceLine > 0
                    }
            },
            "每个 Sheet 目标分支必须提供可核查的 Android 类比"
        )
    }

    var productionCount: Int {
        callSites.lazy.filter { $0.origin == .production }.count
    }

    var debugCount: Int {
        callSites.lazy.filter { $0.origin == .debug }.count
    }

    var hostFileCount: Int {
        Set(callSites.map(\.sourcePath)).count
    }

    var targetCount: Int {
        callSites.lazy.map(\.targets.count).reduce(0, +)
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var familySummaries: [SheetCatalogFamilySummary] {
        SheetCatalogFamily.allCases.compactMap { family in
            let sites = callSites.filter { $0.family == family }
            guard !sites.isEmpty else { return nil }
            return SheetCatalogFamilySummary(
                family: family,
                productionCount: sites.filter { $0.origin == .production }.count,
                debugCount: sites.filter { $0.origin == .debug }.count,
                targetOwnerCount: Set(sites.flatMap(\.targets).map(\.owner)).count
            )
        }
    }

    var visibleFamilySummaries: [SheetCatalogFamilySummary] {
        guard !normalizedSearchText.isEmpty else { return familySummaries }
        return familySummaries.filter { summary in
            summary.family.title.localizedCaseInsensitiveContains(normalizedSearchText)
                || summary.family.summary.localizedCaseInsensitiveContains(normalizedSearchText)
                || callSites.contains { site in
                    site.family == summary.family
                        && site.searchableText.localizedCaseInsensitiveContains(normalizedSearchText)
                }
        }
    }

    func callSites(
        for family: SheetCatalogFamily,
        origin: SheetCatalogOrigin
    ) -> [SheetCatalogCallSite] {
        callSites.filter { site in
            site.family == family
                && site.origin == origin
                && (normalizedSearchText.isEmpty
                    || site.searchableText.localizedCaseInsensitiveContains(normalizedSearchText))
        }
    }

    func hasVisibleCallSites(for family: SheetCatalogFamily) -> Bool {
        SheetCatalogOrigin.allCases.contains { origin in
            !callSites(for: family, origin: origin).isEmpty
        }
    }

    func presentPreview(for target: SheetCatalogTarget) {
        guard target.productionPreview != nil else { return }
        presentedPreview = SheetCatalogPreviewRequest(target: target)
    }
}

private struct SheetCatalogTargetDefinition {
    let owner: String
    let sheetPurpose: String
    let androidAnalogue: SheetCatalogAndroidAnalogue
}

private enum SheetCatalogAndroidEvidence {
    static let tagManagement = [
        ref(.launchEntry, "TagManageActivity", "app/src/main/java/com/merpyzf/xmnote/ui/tag/activity/TagManageActivity.kt", 34),
        ref(.targetOwner, "TagManageFragment", "app/src/main/java/com/merpyzf/xmnote/ui/tag/fragment/TagManageFragment.kt", 47)
    ]
    static let collectionEditing = [
        ref(.launchEntry, "EditCollectionActivity", "app/src/main/java/com/merpyzf/xmnote/ui/main/activity/book/EditCollectionActivity.kt", 50),
        ref(.targetOwner, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47)
    ]
    static let collectionList = [
        ref(.launchEntry, "CollectionListFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/CollectionListFragment.kt", 47)
    ]
    static let collectionMetadata = [
        ref(.launchEntry, "EditCollectionBookActivity", "app/src/main/java/com/merpyzf/xmnote/ui/book/activity/EditCollectionBookActivity.kt", 70)
    ]
    static let wereadImport = [
        ref(.launchEntry, "WeReadBatchImportActivity", "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/weread/WeReadBatchImportActivity.kt", 84)
    ]
    static let bookshelfDisplay = [
        ref(.launchEntry, "BookShelfFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/BookShelfFragment.kt", 51),
        ref(.targetOwner, "BookShelfDisplaySettingBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/compose/bottomsheet/BookShelfDisplaySettingBottomSheet.kt", 82)
    ]
    static let bookshelfBatch = [
        ref(.launchEntry, "DefaultBookListFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/DefaultBookListFragment.kt", 176)
    ]
    static let bookSource = [
        ref(.targetOwner, "BookSourceBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/compose/bottomsheet/BookSourceBottomSheet.kt", 102)
    ]
    static let readingStatus = [
        ref(.targetOwner, "ReadingStatusBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/compose/bottomsheet/ReadingStatusBottomSheet.kt", 99)
    ]
    static let bookGroup = [
        ref(.targetOwner, "BookGroupPickerBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/compose/bottomsheet/BookGroupPickerBottomSheet.kt", 136)
    ]
    static let collectionPicker = [
        ref(.targetOwner, "CollectionPickerBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/book/compose/bottomsheet/CollectionPickerBottomSheet.kt", 80)
    ]
    static let relatedCategory = [
        ref(.launchEntry, "RelevantListFragment", "app/src/main/java/com/merpyzf/xmnote/ui/note/fragment/RelevantListFragment.kt", 49),
        ref(.targetOwner, "RelevantCategoryPickerBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/note/compose/RelevantCategoryPickerBottomSheet.kt", 52)
    ]
    static let rating = [
        ref(.launchEntry, "NoteManagerActivity", "app/src/main/java/com/merpyzf/xmnote/ui/note/activity/NoteManagerActivity.kt", 150),
        ref(.targetOwner, "RatingDialog", "app/src/main/java/com/merpyzf/xmnote/ui/compose/components/MaterialDialog.kt", 773)
    ]
    static let relatedBook = [
        ref(.launchEntry, "showBookSearchSheet 调用", "app/src/main/java/com/merpyzf/xmnote/ui/note/fragment/RelevantListFragment.kt", 303),
        ref(.targetOwner, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47)
    ]
    static let readingDetail = [
        ref(.launchEntry, "BookReadingDetailActivity", "app/src/main/java/com/merpyzf/xmnote/ui/book/activity/reading_detail/BookReadingDetailActivity.kt", 33),
        ref(.targetOwner, "ReadingDetailSettingBottomSheet / ShareSettingBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/activity/reading_detail/screen/BottomSheet.kt", 60)
    ]
    static let chapterManagement = [
        ref(.launchEntry, "ChapterManagerActivity", "app/src/main/java/com/merpyzf/xmnote/ui/chapter/activity/ChapterManagerActivity.kt", 33)
    ]
    static let chapterRemote = [
        ref(.launchEntry, "ChapterManagerActivity", "app/src/main/java/com/merpyzf/xmnote/ui/chapter/activity/ChapterManagerActivity.kt", 33),
        ref(.targetOwner, "ChapterRemoteSyncBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/chapter/compose/bottomsheet/ChapterRemoteSyncBottomSheet.kt", 74)
    ]
    static let chapterBatch = [
        ref(.launchEntry, "BatchAddChapterActivity", "app/src/main/java/com/merpyzf/xmnote/ui/chapter/activity/BatchAddChapterActivity.kt", 41)
    ]
    static let coverSearch = [
        ref(.launchEntry, "SearchCoverActivity", "app/src/main/java/com/merpyzf/xmnote/ui/book/activity/SearchCoverActivity.kt", 29)
    ]
    static let sharing = [
        ref(.targetOwner, "ShareHelper", "common/src/main/java/com/merpyzf/common/utils/ShareHelper.kt", 8)
    ]
    static let bookSearch = [
        ref(.launchEntry, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47),
        ref(.targetOwner, "BookSearchSheetContent", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetContent.kt", 145)
    ]
    static let noteReview = [
        ref(.launchEntry, "NoteReviewFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/note/NoteReviewFragment.kt", 75)
    ]
    static let noteReviewSettings = [
        ref(.launchEntry, "NoteReviewSettingActivity", "app/src/main/java/com/merpyzf/xmnote/ui/main/activity/note/NoteReviewSettingActivity.kt", 77)
    ]
    static let aiInteraction = [
        ref(.targetOwner, "AIAssistantMenuBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/compose/bottomsheet/AIAssistantMenuBottomSheet.kt", 48)
    ]
    static let autoTag = [
        ref(.launchEntry, "NoteReviewFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/note/NoteReviewFragment.kt", 75),
        ref(.targetOwner, "AutoTagBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/compose/bottomsheet/AutoTagBottomSheet.kt", 71)
    ]
    static let noteEditor = [
        ref(.launchEntry, "NoteEditActivity", "app/src/main/java/com/merpyzf/xmnote/ui/note/activity/NoteEditActivity.kt", 157)
    ]
    static let noteEditorBookSearch = [
        ref(.launchEntry, "showBookSearchSheet 调用", "app/src/main/java/com/merpyzf/xmnote/ui/note/activity/NoteEditActivity.kt", 582),
        ref(.targetOwner, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47)
    ]
    static let noteMerge = [
        ref(.launchEntry, "NotesMergeActivity", "app/src/main/java/com/merpyzf/xmnote/ui/note/activity/NotesMergeActivity.kt", 113),
        ref(.targetOwner, "NotesMergeSortDialogFragment", "app/src/main/java/com/merpyzf/xmnote/ui/note/fragment/NotesMergeSortDialogFragment.kt", 37)
    ]
    static let relatedCategoryManagement = [
        ref(.launchEntry, "RelatedNoteCategoriesFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/note/RelatedNoteCategoriesFragment.kt", 99)
    ]
    static let aiConfiguration = [
        ref(.launchEntry, "AIConfigurationActivity", "app/src/main/java/com/merpyzf/xmnote/ui/setting/activity/AIConfigurationActivity.kt", 54)
    ]
    static let apiIntegration = [
        ref(.launchEntry, "ApiIntegrationActivity", "app/src/main/java/com/merpyzf/xmnote/ui/setting/activity/ApiIntegrationActivity.kt", 69)
    ]
    static let backup = [
        ref(.launchEntry, "BackupActivity", "app/src/main/java/com/merpyzf/xmnote/ui/backup/activity/BackupActivity.kt", 64)
    ]
    static let documentPicker = [
        ref(.launchEntry, "BackupActivity", "app/src/main/java/com/merpyzf/xmnote/ui/backup/activity/BackupActivity.kt", 64),
        ref(.targetOwner, "OpenMultipleDocuments.createIntent", "app/src/main/java/com/merpyzf/xmnote/helper/ActivityResultContracts.kt", 36)
    ]
    static let webdav = [
        ref(.launchEntry, "WebDavServerManagerActivity", "app/src/main/java/com/merpyzf/xmnote/ui/backup/activity/WebDavServerManagerActivity.kt", 57)
    ]
    static let groupName = [
        ref(.launchEntry, "GroupManageActivity", "app/src/main/java/com/merpyzf/xmnote/ui/group/activity/GroupManageActivity.kt", 106),
        ref(.targetOwner, "GroupNameInputDialog", "app/src/main/java/com/merpyzf/xmnote/ui/group/activity/GroupManageActivity.kt", 701)
    ]
    static let sourceName = [
        ref(.launchEntry, "GroupBooksActivity", "app/src/main/java/com/merpyzf/xmnote/ui/main/activity/book/GroupBooksActivity.kt", 188),
        ref(.targetOwner, "BookSourceNameInputDialog", "app/src/main/java/com/merpyzf/xmnote/ui/main/activity/book/GroupBooksActivity.kt", 2137)
    ]
    static let tagName = [
        ref(.launchEntry, "TagManageActivity", "app/src/main/java/com/merpyzf/xmnote/ui/tag/activity/TagManageActivity.kt", 34),
        ref(.targetOwner, "TagNameInputDialog", "app/src/main/java/com/merpyzf/xmnote/ui/main/activity/book/GroupBooksActivity.kt", 2209)
    ]
    static let importData = [
        ref(.launchEntry, "ImportActivity", "app/src/main/java/com/merpyzf/xmnote/ui/data/activity/import_note/ImportActivity.kt", 40),
        ref(.targetOwner, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47)
    ]
    static let dailyReading = [
        ref(.launchEntry, "DailyReadingActivity", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/DailyReadingActivity.kt", 33),
        ref(.targetOwner, "DailyReadingBookActivity", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/DailyReadingBookActivity.kt", 69)
    ]
    static let checkIn = [
        ref(.launchEntry, "showCheckInDialog", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/DailyReadingActivity.kt", 128),
        ref(.targetOwner, "CheckInDialog", "app/src/main/java/com/merpyzf/xmnote/ui/common/dialog/CheckInDialog.kt", 31)
    ]
    static let readCalendar = [
        ref(.launchEntry, "ReadCalendarActivity", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/ReadCalendarActivity.kt", 39)
    ]
    static let readCalendarSummary = [
        ref(.launchEntry, "onYearSummaryRequested", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/ReadCalendarActivity.kt", 178),
        ref(.targetOwner, "ReadCalendarSummarySheet", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/compose/ReadCalendarSummarySheet.kt", 181)
    ]
    static let readCalendarSettings = [
        ref(.launchEntry, "ReadCalendarSettingActivity", "app/src/main/java/com/merpyzf/xmnote/ui/setting/activity/ReadCalendarSettingActivity.kt", 34)
    ]
    static let readCalendarShare = [
        ref(.launchEntry, "ShareReadCalendarActivity", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/ShareReadCalendarActivity.kt", 56)
    ]
    static let readingDashboard = [
        ref(.launchEntry, "ReadingFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/statistics/ReadingFragment.kt", 90)
    ]
    static let readingGoal = [
        ref(.launchEntry, "ReadPlanEditActivity", "app/src/main/java/com/merpyzf/xmnote/ui/reminder/ReadPlanEditActivity.kt", 61)
    ]
    static let heatmap = [
        ref(.launchEntry, "ReadingFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/statistics/ReadingFragment.kt", 90),
        ref(.targetOwner, "HeatChartSettingActivity", "app/src/main/java/com/merpyzf/xmnote/ui/setting/activity/HeatChartSettingActivity.kt", 130)
    ]
    static let timing = [
        ref(.launchEntry, "ReadTimingActivity", "app/src/main/java/com/merpyzf/xmnote/ui/time/activity/ReadTimingActivity.kt", 23),
        ref(.targetOwner, "ReadTimingFragment", "app/src/main/java/com/merpyzf/xmnote/ui/time/fragment/ReadTimingFragment.kt", 67)
    ]
    static let timingRecord = [
        ref(.launchEntry, "ReadTimeRecordActivity", "app/src/main/java/com/merpyzf/xmnote/ui/time/activity/ReadTimeRecordActivity.kt", 75),
        ref(.targetOwner, "showBookSearchSheet", "app/src/main/java/com/merpyzf/xmnote/ui/book/bottom_sheet/BookSearchSheetLauncher.kt", 47)
    ]
    static let yearMonth = [
        ref(.launchEntry, "TimelineFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/statistics/TimelineFragment.kt", 116),
        ref(.targetOwner, "YearMonthPickerBottomSheet", "app/src/main/java/com/merpyzf/xmnote/ui/compose/bottomsheet/YearMonthPickerBottomSheet.kt", 211)
    ]
    static let debugBottomSheet = [
        ref(.targetOwner, "AppBottomSheetScaffold", "app/src/main/java/com/merpyzf/xmnote/ui/compose/components/AppBottomSheetScaffold.kt", 131)
    ]
    static let debugNoteReview = [
        ref(.targetOwner, "NoteReviewFragment", "app/src/main/java/com/merpyzf/xmnote/ui/main/fragment/note/NoteReviewFragment.kt", 75)
    ]
    static let debugCalendarCover = [
        ref(.launchEntry, "ReadCalendarActivity", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/ReadCalendarActivity.kt", 39),
        ref(.targetOwner, "ReadCalendarScreen", "app/src/main/java/com/merpyzf/xmnote/ui/read_calendar/compose/ReadCalendarScreen.kt", 184)
    ]

    private static func ref(
        _ role: SheetCatalogAndroidReferenceRole,
        _ owner: String,
        _ sourcePath: String,
        _ sourceLine: Int
    ) -> SheetCatalogAndroidReference {
        SheetCatalogAndroidReference(
            role: role,
            owner: owner,
            sourcePath: sourcePath,
            sourceLine: sourceLine
        )
    }
}

private enum SheetCatalogManifest {
    static let callSites: [SheetCatalogCallSite] = uiComponents + book + content + debug + note + personal + reading

    private static let uiComponents: [SheetCatalogCallSite] = [
        site("ui.tag-selection.name", .production, "UIComponents", "XMTagSelectionSheet", "xmnote/UIComponents/Business/Tag/XMTagSelectionSheet.swift", 170, .item, .scaffoldBottomAction, nested: true, purpose: "用户在标签选择过程中继续创建新标签或重命名现有标签", targets: [
            target("XMTagNameSheet · 新建", "输入名称并创建可立即选用的新标签", "Android 标签管理中新增标签的命名弹窗", SheetCatalogAndroidEvidence.tagManagement),
            target("XMTagNameSheet · 重命名", "修改当前标签名称并回到原选择流程", "Android 标签管理中编辑标签名称的弹窗", SheetCatalogAndroidEvidence.tagManagement)
        ])
    ]

    private static let book: [SheetCatalogCallSite] = [
        site("book.collection-detail.picker", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 125, .isPresented, .nativeToolbar, purpose: "从书单详情向当前书单批量添加本地或在线书籍", targets: [
            target("BookPickerView · iOS 26 系统工具栏", "搜索并多选书籍，通过顶部确认加入当前书单", "Android 编辑书单时通过选书 Sheet 批量加入书籍", SheetCatalogAndroidEvidence.collectionEditing)
        ]),
        site("book.collection-detail.summary", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 141, .isPresented, .scaffoldClose, purpose: "查看当前书单的统计摘要和构成信息", targets: [
            target("BookCollectionSummarySheet", "汇总书单中的数量、阅读状态和时间信息", "Android 书单详情页查看书单内容与概览", SheetCatalogAndroidEvidence.collectionList)
        ]),
        site("book.collection-detail.form", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 146, .item, .scaffoldBottomAction, purpose: "在书单详情中编辑当前书单的名称和基础属性", targets: [
            target("BookCollectionFormSheet", "修改书单名称、类型和说明并保存", "Android 编辑书单页面维护书单基础信息", SheetCatalogAndroidEvidence.collectionEditing)
        ]),
        site("book.collection-detail.annual-description", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 154, .item, .scaffoldBottomAction, purpose: "编辑年度书单在详情页展示的年度说明", targets: [
            target("BookCollectionAnnualDescriptionSheet", "录入并保存年度书单说明", "Android 编辑年度书单时维护书单描述", SheetCatalogAndroidEvidence.collectionEditing)
        ]),
        site("book.collection-detail.recommend", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 162, .item, .scaffoldBottomAction, purpose: "为书单中的某本书补充推荐语和展示信息", targets: [
            target("BookCollectionRecommendSheet", "编辑书籍在书单中的推荐理由和封面", "Android 编辑书单内单本书的收藏理由和元数据", SheetCatalogAndroidEvidence.collectionMetadata)
        ]),
        site("book.collection-detail.metadata", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 177, .item, .scaffoldBottomAction, purpose: "修正书单内书籍的标题、作者、出版社等元数据", targets: [
            target("BookCollectionBookMetadataEditSheet", "编辑书单内单本书的基础元数据", "Android 书单内书籍编辑页维护书籍元数据", SheetCatalogAndroidEvidence.collectionMetadata)
        ]),
        site("book.collection-detail.share", .production, "书籍", "BookCollectionDetailView", "xmnote/Views/Book/BookCollectionDetailView.swift", 187, .item, .systemControllerBridge, purpose: "把生成的书单分享内容交给系统分享面板", targets: [
            target("XMActivityShareSheet", "选择系统目标分享书单图片或文本", "Android 通过 ACTION_SEND 分享书单内容", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("book.collection-list.form", .production, "书籍", "BookCollectionListView", "xmnote/Views/Book/BookCollectionListView.swift", 61, .item, .scaffoldBottomAction, purpose: "从书单列表新建书单或编辑已有书单", targets: [
            target("BookCollectionFormSheet", "填写书单名称、类型和说明并保存", "Android 书单列表进入新建或编辑书单页面", SheetCatalogAndroidEvidence.collectionList)
        ]),
        site("book.collection-list.weread-import", .production, "书籍", "BookCollectionListView", "xmnote/Views/Book/BookCollectionListView.swift", 69, .item, .scaffoldPairedActions, purpose: "从书单列表发起微信读书书单导入", targets: [
            target("BookCollectionWereadImportSheet", "粘贴或输入微信读书数据并开始解析", "Android 微信读书批量导入流程选择并解析导入数据", SheetCatalogAndroidEvidence.wereadImport)
        ]),
        site("book.collection-list.import-preview", .production, "书籍", "BookCollectionListView", "xmnote/Views/Book/BookCollectionListView.swift", 76, .item, .scaffoldPairedActions, purpose: "在写入前检查微信读书书单解析结果", targets: [
            target("BookCollectionWereadImportPreviewSheet", "预览待创建书单和书籍并确认导入", "Android 微信读书批量导入页预览并提交解析结果", SheetCatalogAndroidEvidence.wereadImport)
        ]),
        site("book.container.bookshelf-display", .production, "书籍", "BookContainerView", "xmnote/Views/Book/BookContainerView.swift", 204, .isPresented, .scaffoldClose, purpose: "调整首页书架当前维度的显示和排序偏好", targets: [
            target("BookshelfDisplaySettingSheet", "修改书架布局、排序和辅助信息显示", "Android 书架显示设置 BottomSheet", SheetCatalogAndroidEvidence.bookshelfDisplay)
        ]),
        site("book.container.collection-display", .production, "书籍", "BookContainerView", "xmnote/Views/Book/BookContainerView.swift", 213, .isPresented, .scaffoldClose, purpose: "调整首页书单区域的显示和排序偏好", targets: [
            target("BookCollectionDisplaySettingSheet", "修改书单列表的布局与排序方式", "Android 书单列表中的显示与排序设置", SheetCatalogAndroidEvidence.collectionList)
        ]),
        site("book.container.batch", .production, "书籍", "BookContainerView", "xmnote/Views/Book/BookContainerView.swift", 225, .item, .scaffoldPairedActions, purpose: "对首页书架中已勾选的书籍执行批量归类操作", targets: [
            target("BookshelfBatchTagsSheet", "批量添加或移除书籍标签", "Android 书架批量管理中的标签操作", SheetCatalogAndroidEvidence.bookshelfBatch),
            target("BookshelfBatchSourceSheet", "批量修改书籍来源", "Android 书架批量管理中的来源选择", SheetCatalogAndroidEvidence.bookSource),
            target("BookshelfBatchReadStatusSheet", "批量修改阅读状态", "Android 书架批量管理中的阅读状态选择", SheetCatalogAndroidEvidence.readingStatus),
            target("BookshelfMoveGroupSheet", "把已选书籍移动到目标分组", "Android 书架批量管理中的分组选择", SheetCatalogAndroidEvidence.bookGroup),
            target("BookshelfBookCollectionSheet", "把已选书籍加入一个或多个书单", "Android 书架批量管理中的书单选择", SheetCatalogAndroidEvidence.collectionPicker)
        ]),
        site("book.detail.related-category", .production, "书籍", "BookDetailView", "xmnote/Views/Book/BookDetailView.swift", 587, .isPresented, .nativeToolbar, purpose: "为当前书籍选择它关联的内容分类", targets: [
            target("相关分类选择 NavigationStack", "选择或取消当前书籍关联的分类", "Android 相关内容页使用分类选择 BottomSheet", SheetCatalogAndroidEvidence.relatedCategory)
        ]),
        site("book.detail.rating", .production, "书籍", "BookDetailView", "xmnote/Views/Book/BookDetailView.swift", 590, .isPresented, .customBusinessShell, purpose: "在书籍详情中记录或修改个人评分", targets: [
            target("XMBookRatingSheet", "选择半星精度评分并即时写回当前书籍", "Android 单书管理中的评分 Dialog", SheetCatalogAndroidEvidence.rating)
        ]),
        site("book.detail.relation-editor", .production, "书籍", "BookDetailView", "xmnote/Views/Book/BookDetailView.swift", 597, .item, .customBusinessShell, purpose: "维护当前书籍与其他书籍之间的关系", targets: [
            target("RelatedBookRelationEditorSheet", "选择相关书籍并编辑关系说明", "Android 相关内容流程中选择书籍建立关联", SheetCatalogAndroidEvidence.relatedBook)
        ]),
        site("book.reading-detail.destination", .production, "书籍", "BookReadingDetailView", "xmnote/Views/Book/BookReadingDetailView.swift", 51, .item, .customBusinessShell, purpose: "从阅读详情进入进度、状态、设置、分享和封面预览等辅助任务", targets: [
            target("BookReadingProgressSheet", "更新当前书籍的页数或百分比阅读进度", "Android 阅读详情中编辑阅读进度", SheetCatalogAndroidEvidence.readingDetail),
            target("BookReadingStatusSheet · 新建", "新增一条阅读状态记录", "Android 阅读详情中新增阅读状态", SheetCatalogAndroidEvidence.readingStatus),
            target("BookReadingStatusSheet · 编辑", "修改已有阅读状态记录", "Android 阅读详情中编辑阅读状态", SheetCatalogAndroidEvidence.readingStatus),
            target("BookReadingDetailSettingSheet", "调整阅读详情的展示和统计设置", "Android 阅读详情中的设置 BottomSheet", SheetCatalogAndroidEvidence.readingDetail),
            target("BookReadingDetailShareSheet", "配置并生成阅读详情分享内容", "Android 阅读详情分享设置 BottomSheet", SheetCatalogAndroidEvidence.readingDetail),
            target("BookReadingCoverPreview", "放大查看当前阅读书籍封面", "Android 阅读详情中的书籍封面预览", SheetCatalogAndroidEvidence.readingDetail)
        ]),
        site("book.bookshelf-list.display", .production, "书籍", "BookshelfBookListView", "xmnote/Views/Book/BookshelfBookListView.swift", 152, .isPresented, .scaffoldClose, purpose: "调整二级书籍列表的显示和排序偏好", targets: [
            target("BookshelfDisplaySettingSheet", "修改当前列表布局、排序和辅助信息显示", "Android 书架显示设置 BottomSheet", SheetCatalogAndroidEvidence.bookshelfDisplay)
        ]),
        site("book.bookshelf-list.batch", .production, "书籍", "BookshelfBookListView", "xmnote/Views/Book/BookshelfBookListView.swift", 166, .item, .scaffoldPairedActions, purpose: "对二级书籍列表中已勾选的书籍执行批量归类操作", targets: [
            target("BookshelfBatchTagsSheet", "批量添加或移除书籍标签", "Android 书架批量管理中的标签操作", SheetCatalogAndroidEvidence.bookshelfBatch),
            target("BookshelfBatchSourceSheet", "批量修改书籍来源", "Android 书架批量管理中的来源选择", SheetCatalogAndroidEvidence.bookSource),
            target("BookshelfBatchReadStatusSheet", "批量修改阅读状态", "Android 书架批量管理中的阅读状态选择", SheetCatalogAndroidEvidence.readingStatus),
            target("BookshelfMoveGroupSheet", "把已选书籍移动到目标分组", "Android 书架批量管理中的分组选择", SheetCatalogAndroidEvidence.bookGroup),
            target("BookshelfBookCollectionSheet", "把已选书籍加入一个或多个书单", "Android 书架批量管理中的书单选择", SheetCatalogAndroidEvidence.collectionPicker)
        ]),
        site("book.chapter-manager.move", .production, "书籍", "ChapterManagerView", "xmnote/Views/Book/ChapterManagerView.swift", 94, .item, .nativeToolbar, purpose: "在章节管理中为选中章节指定新的父级或位置", targets: [
            target("ChapterMoveSheet", "选择章节移动目标并提交结构调整", "Android 章节管理的移动工作区", SheetCatalogAndroidEvidence.chapterManagement)
        ]),
        site("book.chapter-manager.order", .production, "书籍", "ChapterManagerView", "xmnote/Views/Book/ChapterManagerView.swift", 101, .item, .nativeToolbar, purpose: "重新排列同一层级中的章节顺序", targets: [
            target("ChapterSiblingOrderSheet", "拖动或选择新的同级章节顺序", "Android 章节管理中的同级排序工作区", SheetCatalogAndroidEvidence.chapterManagement)
        ]),
        site("book.chapter-manager.remote-sync", .production, "书籍", "ChapterManagerView", "xmnote/Views/Book/ChapterManagerView.swift", 106, .item, .customBusinessShell, purpose: "从在线书源检索目录并同步到当前书籍", targets: [
            target("ChapterRemoteSyncSheet", "搜索在线目录、勾选章节并确认同步", "Android 章节管理的远程目录同步 BottomSheet", SheetCatalogAndroidEvidence.chapterRemote)
        ]),
        site("book.chapter-manager.batch-import", .production, "书籍", "ChapterManagerView", "xmnote/Views/Book/ChapterManagerView.swift", 109, .item, .customBusinessShell, purpose: "把批量粘贴的章节文本解析为目录结构", targets: [
            target("ChapterBatchImportSheet", "编辑章节文本、预览层级并批量导入", "Android 批量添加章节页面", SheetCatalogAndroidEvidence.chapterBatch)
        ]),
        site("book.collection.recommend.cover-search", .production, "书籍", "BookCollectionRecommendSheet", "xmnote/Views/Book/Sheets/BookCollectionSheets.swift", 473, .isPresented, .scaffoldTopControl, nested: true, purpose: "编辑书单推荐信息时在线查找更合适的封面", targets: [
            target("BookCollectionCoverSearchSheet", "搜索并选择在线封面候选", "Android 书籍封面在线搜索页面", SheetCatalogAndroidEvidence.coverSearch)
        ]),
        site("book.picker.selected-books", .production, "书籍", "BookPickerView", "xmnote/Views/Book/Sheets/BookPickerView.swift", 158, .item, .scaffoldTopControl, nested: true, purpose: "在多选书籍过程中集中查看和移除已选书籍", targets: [
            target("BookPickerSelectedBooksScreen", "搜索已选项并取消不需要的选择", "Android 选书 Sheet 中查看和管理多选结果", SheetCatalogAndroidEvidence.bookSearch)
        ]),
        site("book.reading-share.options", .production, "书籍", "BookReadingDetailShareSheet", "xmnote/Views/Book/Sheets/BookReadingDetailShareSheet.swift", 94, .isPresented, .nativeToolbar, nested: true, purpose: "生成阅读详情分享图前配置可见内容", targets: [
            target("分享选项 Form + Toolbar", "选择分享图包含的字段和排版选项", "Android 阅读详情分享设置 BottomSheet", SheetCatalogAndroidEvidence.readingDetail)
        ]),
        site("book.reading-share.activity", .production, "书籍", "BookReadingDetailShareSheet", "xmnote/Views/Book/Sheets/BookReadingDetailShareSheet.swift", 97, .isPresented, .systemControllerBridge, nested: true, purpose: "把已生成的阅读详情图片交给系统分享面板", targets: [
            target("XMActivityShareSheet", "选择系统目标分享阅读详情图片", "Android 通过 ACTION_SEND 分享阅读详情内容", SheetCatalogAndroidEvidence.sharing)
        ])
    ]

    private static let content: [SheetCatalogCallSite] = [
        site("content.viewer.tags", .production, "内容", "ContentViewerView", "xmnote/Views/Content/ContentViewerView.swift", 235, .isPresented, .scaffoldTopAndBottom, purpose: "在内容阅读页查看和修改当前内容的标签", targets: [
            target("ContentViewerTagSheet", "搜索、选择或新建标签并保存到当前内容", "Android 笔记查看页中的标签选择流程", SheetCatalogAndroidEvidence.tagManagement)
        ]),
        site("content.viewer.tag-edit", .production, "内容", "ContentViewerView", "xmnote/Views/Content/ContentViewerView.swift", 243, .item, .customBusinessShell, purpose: "从内容阅读页编辑当前回顾条目的标签", targets: [
            target("NoteReviewTagEditSheet", "修改当前内容关联的回顾标签", "Android 回顾页面的标签编辑流程", SheetCatalogAndroidEvidence.noteReview)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("content.viewer.share", .production, "内容", "ContentViewerView", "xmnote/Views/Content/ContentViewerView.swift", 264, .item, .systemControllerBridge, purpose: "把当前内容的文本或生成图片交给系统分享面板", targets: [
            target("XMActivityShareSheet", "选择系统目标分享当前内容", "Android 通过 ACTION_SEND 分享笔记或书摘", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("content.viewer.ai-text", .production, "内容", "ContentViewerView", "xmnote/Views/Content/ContentViewerView.swift", 267, .item, .customBusinessShell, purpose: "对当前内容执行 AI 文本任务并查看流式结果", targets: [
            target("AITextResultSheet", "展示 AI 生成文本、错误和取消状态", "Android AI 助手 BottomSheet 中执行文本任务", SheetCatalogAndroidEvidence.aiInteraction)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("content.viewer.auto-tag", .production, "内容", "ContentViewerView", "xmnote/Views/Content/ContentViewerView.swift", 281, .item, .customBusinessShell, purpose: "让 AI 为当前内容生成标签建议并应用", targets: [
            target("AIAutoTagSheet", "展示标签建议、调整选择并写回当前内容", "Android 自动标签 BottomSheet", SheetCatalogAndroidEvidence.autoTag)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("content.relevant.ai-text", .production, "内容", "RelevantDetailView", "xmnote/Views/Content/RelevantDetailView.swift", 97, .item, .customBusinessShell, purpose: "在相关内容详情中对选中文本执行 AI 任务", targets: [
            target("AITextResultSheet", "展示相关内容的 AI 生成结果", "Android AI 助手 BottomSheet 中执行文本任务", SheetCatalogAndroidEvidence.aiInteraction)
        ]),
        site("content.review.ai-text", .production, "内容", "ReviewDetailView", "xmnote/Views/Content/ReviewDetailView.swift", 97, .item, .customBusinessShell, purpose: "在想法详情中对选中文本执行 AI 任务", targets: [
            target("AITextResultSheet", "展示想法内容的 AI 生成结果", "Android AI 助手 BottomSheet 中执行文本任务", SheetCatalogAndroidEvidence.aiInteraction)
        ]),
        site("content.ai-interaction.share-one", .production, "内容", "AITextResultSheet", "xmnote/Views/Content/Sheets/AIInteractionSheets.swift", 199, .item, .systemControllerBridge, nested: true, purpose: "从 AI 文本结果中分享生成内容", targets: [
            target("XMActivityShareSheet", "选择系统目标分享 AI 生成文本", "Android 通过 ACTION_SEND 分享 AI 处理结果", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("content.ai-interaction.share-two", .production, "内容", "AIAutoTagSheet", "xmnote/Views/Content/Sheets/AIInteractionSheets.swift", 607, .item, .systemControllerBridge, nested: true, purpose: "从自动标签结果中分享处理内容", targets: [
            target("XMActivityShareSheet", "选择系统目标分享自动标签结果", "Android 通过 ACTION_SEND 分享 AI 处理结果", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("content.related-book.picker", .production, "内容", "RelatedBookRelationEditorSheet", "xmnote/Views/Content/Sheets/RelatedBookRelationEditorSheet.swift", 84, .isPresented, .customBusinessShell, nested: true, purpose: "在关系编辑流程中选择要关联的目标书籍", targets: [
            target("BookPickerView", "搜索并选择一本文档关系目标书籍", "Android 相关内容页通过选书 Sheet 建立书籍关系", SheetCatalogAndroidEvidence.relatedBook)
        ])
    ]

    private static let debug: [SheetCatalogCallSite] = [
        site("debug.sheet-catalog.preview", .debug, "Debug", "SheetCatalogFamilyDetailView", "xmnote/Views/Debug/Sheets/SheetCatalogTestView.swift", 442, .item, .customBusinessShell, purpose: "从 Sheet 校准详情按目标打开隔离生产数据下的真实生产 Sheet", targets: [
            target("SheetProductionTargetPreviewHost", "为所选生产目标创建独立数据库副本并实例化对应生产 View", "Android BottomSheet Playground 中切换并观察弹层结构", SheetCatalogAndroidEvidence.debugBottomSheet)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("debug.book-selection", .debug, "Debug", "BookSelectionTestView", "xmnote/Views/Debug/BookSelectionTestView.swift", 36, .item, .scaffoldDynamicSubtitle, purpose: "用固定数据验收生产书籍选择 Sheet 的系统壳层和异步确认行为", targets: [
            target("BookPickerView · 当前标准", "观察自定义标题栏与底部全宽确认的现有实现", "Android 通用选书 Sheet 的多选与确认流程", SheetCatalogAndroidEvidence.bookSearch),
            target("BookPickerView · Apple 推荐", "观察系统工具栏、顶部确认和滚动边缘的候选实现", "Android 通用选书 Sheet 的多选与确认流程", SheetCatalogAndroidEvidence.bookSearch)
        ], facts: .mediumLarge(family: .scaffoldDynamicSubtitle)),
        site("debug.design-gallery.scaffold", .debug, "Debug", "DesignSystemGalleryView", "xmnote/Views/Debug/DesignSystemGalleryView.swift", 77, .isPresented, .scaffoldClose, purpose: "从设计系统画廊打开基础 Sheet 骨架进行视觉验收", targets: [
            target("XMSheetScaffold 样例", "观察标题、关闭、滚动和系统 detent 的基础组合", "Android AppBottomSheetScaffold 的基础结构样例", SheetCatalogAndroidEvidence.debugBottomSheet)
        ]),
        site("debug.design-gallery.tags", .debug, "Debug", "DesignSystemGalleryView", "xmnote/Views/Debug/DesignSystemGalleryView.swift", 80, .isPresented, .scaffoldTopAndBottom, purpose: "从设计系统画廊验收标签选择 Sheet 的完整状态", targets: [
            target("XMTagSelectionSheet", "观察搜索、选择、创建和确认状态", "Android 标签管理与标签选择场景", SheetCatalogAndroidEvidence.tagManagement)
        ]),
        site("debug.design-gallery.share", .debug, "Debug", "DesignSystemGalleryView", "xmnote/Views/Debug/DesignSystemGalleryView.swift", 84, .item, .systemControllerBridge, purpose: "从设计系统画廊验证系统分享桥接呈现", targets: [
            target("XMActivityShareSheet", "使用固定无敏感文本打开系统分享面板", "Android ShareHelper 打开 ACTION_SEND chooser", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("debug.liquid-glass.parameters", .debug, "Debug", "LiquidGlassLabTestView", "xmnote/Views/Debug/LiquidGlassLabTestView.swift", 52, .isPresented, .customBusinessShell, purpose: "调整 Liquid Glass 实验参数并观察不同表层组合", targets: [
            target("Liquid Glass 参数面板", "修改实验参数而不影响生产设计系统", "Android BottomSheet Playground 中调整和观察弹层参数", SheetCatalogAndroidEvidence.debugBottomSheet)
        ], facts: .mediumLarge(family: .customBusinessShell, backgroundInteraction: ".enabled(upThrough: .medium)")),
        site("debug.note-review-paging.config", .debug, "Debug", "NoteReviewPagingTestView", "xmnote/Views/Debug/NoteReviewPagingTestView.swift", 57, .isPresented, .customBusinessShell, purpose: "配置书摘回顾分页实验的数据量和翻页条件", targets: [
            target("NoteReviewPagingConfigSheet", "修改固定测试数据和分页参数", "Android NoteReviewFragment 的回顾卡片分页场景", SheetCatalogAndroidEvidence.debugNoteReview)
        ], facts: .mediumLarge(family: .customBusinessShell, background: ".regularMaterial")),
        site("debug.calendar-cover-stack.config", .debug, "Debug", "ReadCalendarCoverStackTestView", "xmnote/Views/Debug/ReadCalendarCoverStackTestView.swift", 51, .isPresented, .customBusinessShell, purpose: "配置阅读日历封面堆叠实验的数量、层级和交互参数", targets: [
            target("ReadCalendarCoverStackConfigSheet", "修改固定封面堆叠测试参数", "Android ReadCalendarScreen 的封面堆叠展示场景", SheetCatalogAndroidEvidence.debugCalendarCover)
        ], facts: SheetCatalogPresentationFacts(detents: ".fraction(0.55) / .large", dragIndicator: ".visible", background: ".regularMaterial", backgroundInteraction: ".enabled", contentInteraction: ".scrolls", actionPlacement: "由 Debug 参数壳层声明", interactiveDismissal: "未显式锁定"))
    ]

    private static let note: [SheetCatalogCallSite] = [
        site("note.collection.rating", .production, "书摘", "NoteCollectionView", "xmnote/Views/Note/NoteCollectionView.swift", 70, .item, .customBusinessShell, purpose: "从书摘书籍列表记录或修改某本书的个人评分", targets: [
            target("XMBookRatingSheet", "选择半星精度评分并即时写回书籍", "Android 单书管理中的评分 Dialog", SheetCatalogAndroidEvidence.rating)
        ]),
        site("note.container.review-settings", .production, "书摘", "NoteContainerView", "xmnote/Views/Note/NoteContainerView.swift", 176, .isPresented, .scaffoldClose, purpose: "调整书摘回顾的范围、排序和卡片显示偏好", targets: [
            target("NoteReviewSettingsSheet", "配置参与回顾的书籍、标签和展示规则", "Android 书摘回顾设置页面", SheetCatalogAndroidEvidence.noteReviewSettings)
        ]),
        site("note.editor.composer", .production, "书摘", "NoteEditorView", "xmnote/Views/Note/NoteEditorView.swift", 408, .item, .nativeToolbar, purpose: "在书摘编辑器中打开更完整的正文或想法编辑空间", targets: [
            target("NoteTextComposerView NavigationStack", "编辑长文本内容并确认回填到当前书摘", "Android NoteEditActivity 的全屏文本编辑流程", SheetCatalogAndroidEvidence.noteEditor)
        ]),
        site("note.editor.destination", .production, "书摘", "NoteEditorView", "xmnote/Views/Note/NoteEditorView.swift", 427, .item, .customBusinessShell, purpose: "为正在编辑的书摘补充书籍、章节、标签、日期和编辑设置", targets: [
            target("BookPickerView", "搜索并更换当前书摘所属书籍", "Android NoteEditActivity 中打开通用选书 Sheet", SheetCatalogAndroidEvidence.noteEditorBookSearch),
            target("NoteEditorChapterPickerSheet", "选择当前书摘所属章节", "Android NoteEditActivity 中选择章节", SheetCatalogAndroidEvidence.noteEditor),
            target("NoteEditorTagPickerSheet", "搜索并选择当前书摘标签", "Android NoteEditActivity 中选择标签", SheetCatalogAndroidEvidence.noteEditor),
            target("NoteEditorDateSheet", "修改当前书摘记录日期", "Android NoteEditActivity 中编辑书摘时间", SheetCatalogAndroidEvidence.noteEditor),
            target("NoteEditorSettingsSheet", "调整编辑布局和录入偏好", "Android NoteEditActivity 的编辑设置流程", SheetCatalogAndroidEvidence.noteEditor)
        ]),
        site("note.excerpt.share", .production, "书摘", "NoteExcerptListView", "xmnote/Views/Note/NoteExcerptListView.swift", 79, .item, .systemControllerBridge, purpose: "从书摘列表分享选中的书摘内容", targets: [
            target("XMActivityShareSheet", "选择系统目标分享书摘文本或图片", "Android 通过 ACTION_SEND 分享书摘卡片", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("note.excerpt.batch", .production, "书摘", "NoteExcerptListView", "xmnote/Views/Note/NoteExcerptListView.swift", 98, .item, .customBusinessShell, purpose: "对书摘列表中已勾选的内容批量修改归属", targets: [
            target("BookPickerView", "批量更换已选书摘所属书籍", "Android 笔记管理中通过选书 Sheet 批量归类", SheetCatalogAndroidEvidence.bookSearch),
            target("NoteChapterSelectionSheet", "批量更换已选书摘所属章节", "Android 笔记管理中的章节选择流程", SheetCatalogAndroidEvidence.noteEditor),
            target("NoteTagSelectionSheet", "批量添加或移除已选书摘标签", "Android 笔记管理中的标签选择流程", SheetCatalogAndroidEvidence.tagManagement)
        ]),
        site("note.merge.destination", .production, "书摘", "NoteMergeView", "xmnote/Views/Note/NoteMergeView.swift", 104, .item, .customBusinessShell, purpose: "合并书摘前编辑合并文本、归属信息和附图", targets: [
            target("NoteMergeComposerSheet", "编辑合并后生成的正文内容", "Android 笔记合并流程中的内容整理", SheetCatalogAndroidEvidence.noteMerge),
            target("NoteChapterSelectionSheet", "为合并结果选择目标章节", "Android 笔记合并流程中的章节归属设置", SheetCatalogAndroidEvidence.noteMerge),
            target("NoteTagSelectionSheet", "为合并结果选择标签", "Android 笔记合并流程中的标签设置", SheetCatalogAndroidEvidence.noteMerge),
            target("NoteMergeImageEditorSheet", "调整合并结果中的图片顺序和内容", "Android 笔记合并流程中的媒体整理", SheetCatalogAndroidEvidence.noteMerge)
        ]),
        site("note.review.tag-edit", .production, "书摘", "NoteReviewView", "xmnote/Views/Note/NoteReviewView.swift", 76, .item, .customBusinessShell, purpose: "在回顾卡片上快速修改当前内容的标签", targets: [
            target("NoteReviewTagEditSheet", "搜索、选择或新建标签并写回当前卡片", "Android NoteReviewFragment 的标签编辑流程", SheetCatalogAndroidEvidence.noteReview)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("note.review.ai-text", .production, "书摘", "NoteReviewView", "xmnote/Views/Note/NoteReviewView.swift", 90, .item, .customBusinessShell, purpose: "对当前回顾卡片内容执行 AI 文本任务", targets: [
            target("AITextResultSheet", "展示 AI 生成文本、错误和取消状态", "Android AI 助手 BottomSheet 中处理回顾内容", SheetCatalogAndroidEvidence.aiInteraction)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("note.review.auto-tag", .production, "书摘", "NoteReviewView", "xmnote/Views/Note/NoteReviewView.swift", 104, .item, .customBusinessShell, purpose: "让 AI 为当前回顾卡片生成标签建议", targets: [
            target("AIAutoTagSheet", "审阅标签建议并应用到当前内容", "Android 自动标签 BottomSheet", SheetCatalogAndroidEvidence.autoTag)
        ], facts: .mediumLarge(family: .customBusinessShell)),
        site("note.review.share", .production, "书摘", "NoteReviewView", "xmnote/Views/Note/NoteReviewView.swift", 121, .item, .systemControllerBridge, purpose: "分享当前回顾卡片的书摘或想法内容", targets: [
            target("XMActivityShareSheet", "选择系统目标分享回顾卡片", "Android 通过 ACTION_SEND 分享书摘卡片", SheetCatalogAndroidEvidence.sharing)
        ], facts: .mediumLarge(family: .systemControllerBridge)),
        site("note.related-category.placeholder", .production, "书摘", "RelatedCategoryListView", "xmnote/Views/Note/RelatedCategoryListView.swift", 42, .item, .customBusinessShell, purpose: "解释相关分类中引用书籍缺失或尚未匹配的占位状态", targets: [
            target("BookRelatedPlaceholderSheet", "查看占位书籍信息并选择后续处理方式", "Android 相关内容分类中的缺失书籍处理场景", SheetCatalogAndroidEvidence.relatedCategoryManagement)
        ]),
        site("note.review-settings.destination", .production, "书摘", "NoteReviewSettingsSheet", "xmnote/Views/Note/Sheets/NoteReviewSettingsSheet.swift", 51, .item, .customBusinessShell, nested: true, purpose: "在回顾设置中进一步限定参与回顾的书籍和标签", targets: [
            target("BookPickerView", "选择参与书摘回顾的书籍范围", "Android 回顾设置中的书籍范围选择", SheetCatalogAndroidEvidence.noteReviewSettings),
            target("NoteReviewTagSelectionSheet", "选择参与回顾的标签及匹配规则", "Android 回顾设置中的标签范围选择", SheetCatalogAndroidEvidence.noteReviewSettings)
        ])
    ]

    private static let personal: [SheetCatalogCallSite] = [
        site("personal.ai-config.prompt", .production, "个人", "AIConfigurationView", "xmnote/Views/Personal/AIConfigurationView.swift", 80, .item, .scaffoldBottomAction, purpose: "在 AI 配置页编辑某个任务使用的系统提示词", targets: [
            target("AIConfigurationPromptEditSheet", "编辑、恢复或保存 AI 提示词模板", "Android AIConfigurationActivity 中维护提示词配置", SheetCatalogAndroidEvidence.aiConfiguration)
        ]),
        site("personal.api-integration.edit", .production, "个人", "ApiIntegrationView", "xmnote/Views/Personal/ApiIntegrationView.swift", 75, .item, .scaffoldBottomAction, purpose: "新增或编辑第三方 API 集成配置", targets: [
            target("ApiIntegrationEditSheet", "填写服务名称、地址和凭证并保存", "Android ApiIntegrationActivity 中维护 API 集成", SheetCatalogAndroidEvidence.apiIntegration)
        ]),
        site("personal.backup.history", .production, "个人", "DataBackupView", "xmnote/Views/Personal/Backup/DataBackupView.swift", 107, .isPresented, .scaffoldClose, purpose: "查看本地与远程备份记录及其状态", targets: [
            target("BackupHistorySheetView", "浏览历史备份并选择可恢复版本", "Android BackupActivity 中查看备份记录", SheetCatalogAndroidEvidence.backup)
        ]),
        site("personal.backup.restore", .production, "个人", "DataBackupView", "xmnote/Views/Personal/Backup/DataBackupView.swift", 110, .isPresented, .scaffoldBottomAction, purpose: "在覆盖当前数据前核对并确认备份恢复", targets: [
            target("BackupRestoreConfirmSheet", "展示恢复影响并提交恢复操作", "Android BackupActivity 中确认恢复备份", SheetCatalogAndroidEvidence.backup)
        ]),
        site("personal.backup.export-picker", .production, "个人", "DataBackupView", "xmnote/Views/Personal/Backup/DataBackupView.swift", 128, .isPresented, .systemControllerBridge, purpose: "选择本地备份文件的导出位置", targets: [
            target("LocalBackupExportDocumentPicker", "使用系统文档选择器保存备份文件", "Android 备份页通过系统文档能力导出文件", SheetCatalogAndroidEvidence.documentPicker)
        ]),
        site("personal.backup.import-picker", .production, "个人", "DataBackupView", "xmnote/Views/Personal/Backup/DataBackupView.swift", 136, .isPresented, .systemControllerBridge, purpose: "从系统文件中选择要导入的本地备份", targets: [
            target("LocalBackupImportDocumentPicker", "使用系统文档选择器读取备份文件", "Android 备份页通过 ACTION_OPEN_DOCUMENT 选择文件", SheetCatalogAndroidEvidence.documentPicker)
        ]),
        site("personal.webdav.form", .production, "个人", "WebDAVServerListView", "xmnote/Views/Personal/Backup/WebDAVServerListView.swift", 115, .isPresented, .scaffoldBottomAction, purpose: "新增或编辑 WebDAV 备份服务器", targets: [
            target("WebDAVServerFormView", "填写服务器地址、账号和路径并验证保存", "Android WebDavServerManagerActivity 中维护服务器", SheetCatalogAndroidEvidence.webdav)
        ]),
        site("personal.group.name", .production, "个人", "BookGroupManagementView", "xmnote/Views/Personal/BookGroupManagementView.swift", 249, .item, .scaffoldPairedActions, purpose: "在书籍分组管理中创建分组或修改分组名称", targets: [
            target("BookGroupNameEditSheet", "输入分组名称并确认创建或重命名", "Android GroupManageActivity 的分组名称 Dialog", SheetCatalogAndroidEvidence.groupName)
        ]),
        site("personal.data-import.book", .production, "个人", "DataImportView", "xmnote/Views/Personal/DataImport/DataImportView.swift", 338, .item, .customBusinessShell, purpose: "为传统数据导入任务选择目标书籍", targets: [
            target("BookPickerView", "搜索并指定导入内容应归属的书籍", "Android ImportActivity 中通过选书 Sheet 匹配导入数据", SheetCatalogAndroidEvidence.importData)
        ]),
        site("personal.unified-import.book", .production, "个人", "UnifiedNoteImportView", "xmnote/Views/Personal/DataImport/UnifiedNoteImportViews.swift", 335, .item, .customBusinessShell, purpose: "在统一书摘导入流程中选择或修正目标书籍", targets: [
            target("BookPickerView", "搜索并指定当前导入批次的目标书籍", "Android ImportActivity 中通过选书 Sheet 匹配导入数据", SheetCatalogAndroidEvidence.importData)
        ]),
        site("personal.source.name", .production, "个人", "SourceManagementView", "xmnote/Views/Personal/SourceManagementView.swift", 130, .item, .scaffoldPairedActions, purpose: "在书籍来源管理中创建来源或修改来源名称", targets: [
            target("SourceNameEditSheet", "输入来源名称并确认创建或重命名", "Android GroupBooksActivity 的书籍来源名称 Dialog", SheetCatalogAndroidEvidence.sourceName)
        ]),
        site("personal.tag.name", .production, "个人", "TagManagementView", "xmnote/Views/Personal/TagManagementView.swift", 219, .item, .scaffoldPairedActions, purpose: "在标签管理中创建标签或修改标签名称", targets: [
            target("TagNameEditSheet", "输入标签名称并确认创建或重命名", "Android 标签管理与 TagNameInputDialog", SheetCatalogAndroidEvidence.tagName)
        ])
    ]

    private static let reading: [SheetCatalogCallSite] = [
        site("reading.daily.book-filter", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 72, .isPresented, .scaffoldTopControl, purpose: "筛选某一天只显示指定书籍的阅读记录", targets: [
            target("DailyReadingBookFilterSheet", "搜索并选择日详情中的书籍筛选范围", "Android DailyReadingBookActivity 中按书籍查看日记录", SheetCatalogAndroidEvidence.dailyReading)
        ]),
        site("reading.daily.check-in", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 81, .isPresented, .scaffoldBottomAction, purpose: "从某日阅读详情新增一次阅读打卡", targets: [
            target("ReadCalendarCheckInSheet", "选择书籍、阅读量和日期并保存打卡", "Android DailyReadingActivity 打开的 CheckInDialog", SheetCatalogAndroidEvidence.checkIn)
        ]),
        site("reading.daily.edit", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 98, .item, .customBusinessShell, purpose: "编辑某一天已有的打卡或计时记录", targets: [
            target("ReadCalendarCheckInSheet", "修改已有打卡的书籍、阅读量和日期", "Android DailyReadingBookActivity 中编辑打卡记录", SheetCatalogAndroidEvidence.checkIn),
            target("ReadCalendarTimingEditorSheet", "修改已有阅读计时的书籍、时长和时间", "Android DailyReadingBookActivity 中编辑计时记录", SheetCatalogAndroidEvidence.dailyReading)
        ]),
        site("reading.daily.tag-edit", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 101, .item, .customBusinessShell, purpose: "从某日阅读内容中修改书摘或想法标签", targets: [
            target("NoteReviewTagEditSheet", "搜索并修改当前阅读内容的标签", "Android 日阅读详情中的标签编辑流程", SheetCatalogAndroidEvidence.dailyReading)
        ]),
        site("reading.daily.relation-editor", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 115, .item, .customBusinessShell, purpose: "从某日阅读内容中维护相关书籍关系", targets: [
            target("RelatedBookRelationEditorSheet", "选择相关书籍并编辑关系说明", "Android 相关内容流程中选择书籍建立关联", SheetCatalogAndroidEvidence.relatedBook)
        ]),
        site("reading.daily.share", .production, "阅读", "DailyReadingView", "xmnote/Views/Reading/ReadCalendar/DailyReadingView.swift", 125, .item, .systemControllerBridge, purpose: "分享某一天的阅读记录或内容", targets: [
            target("XMActivityShareSheet", "选择系统目标分享日阅读内容", "Android 通过 ACTION_SEND 分享阅读内容", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("reading.calendar.destination", .production, "阅读", "ReadCalendarContentView", "xmnote/Views/Reading/ReadCalendar/ReadCalendarContentView.swift", 439, .item, .customBusinessShell, purpose: "从阅读日历查看月度、年度总结或快速跳转时间", targets: [
            target("ReadCalendarMonthSummarySheet", "查看指定月份的阅读指标、排行和分布", "Android ReadCalendarSummarySheet 的月度总结", SheetCatalogAndroidEvidence.readCalendarSummary),
            target("ReadCalendarYearSummarySheet", "查看指定年份的阅读指标、排行和分布", "Android ReadCalendarSummarySheet 的年度总结", SheetCatalogAndroidEvidence.readCalendarSummary),
            target("XMYearMonthPickerSheet · 年月", "选择目标年份和月份并跳转日历", "Android 阅读日历中的 YearMonthPickerBottomSheet", SheetCatalogAndroidEvidence.yearMonth),
            target("XMYearMonthPickerSheet · 年份", "只选择目标年份并切换年度视图", "Android 阅读日历中的年份选择模式", SheetCatalogAndroidEvidence.yearMonth)
        ]),
        site("reading.calendar-share.destination", .production, "阅读", "ReadCalendarShareView", "xmnote/Views/Reading/ReadCalendar/ReadCalendarShareView.swift", 57, .item, .customBusinessShell, purpose: "配置阅读日历分享范围、模板、排除书籍并发起系统分享", targets: [
            target("XMYearMonthPickerSheet", "选择要生成分享内容的年月", "Android 阅读日历分享页选择统计周期", SheetCatalogAndroidEvidence.yearMonth),
            target("模板选择 NavigationStack", "选择阅读日历分享图模板", "Android ShareReadCalendarActivity 的分享样式选择", SheetCatalogAndroidEvidence.readCalendarShare),
            target("书籍排除 NavigationStack", "选择不应出现在分享图中的书籍", "Android ShareReadCalendarActivity 的书籍过滤设置", SheetCatalogAndroidEvidence.readCalendarShare),
            target("XMActivityShareSheet", "选择系统目标分享生成的日历图片", "Android 通过 ACTION_SEND 分享阅读日历图片", SheetCatalogAndroidEvidence.sharing)
        ]),
        site("reading.calendar.settings", .production, "阅读", "ReadCalendarView", "xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift", 136, .isPresented, .scaffoldClose, purpose: "调整阅读日历的显示、统计和封面偏好", targets: [
            target("ReadCalendarSettingsSheet", "修改日历外观、统计口径和显示选项", "Android ReadCalendarSettingActivity", SheetCatalogAndroidEvidence.readCalendarSettings)
        ]),
        site("reading.calendar.check-in", .production, "阅读", "ReadCalendarView", "xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift", 139, .isPresented, .scaffoldBottomAction, purpose: "从阅读日历选中日期新增一次阅读打卡", targets: [
            target("ReadCalendarCheckInSheet", "选择书籍、阅读量和日期并保存打卡", "Android ReadCalendarActivity 打开的 CheckInDialog", SheetCatalogAndroidEvidence.checkIn)
        ], facts: .mediumLarge(family: .scaffoldBottomAction)),
        site("reading.check-in.book", .production, "阅读", "ReadCalendarCheckInSheet", "xmnote/Views/Reading/ReadCalendar/Sheets/ReadCalendarCheckInSheet.swift", 127, .isPresented, .customBusinessShell, nested: true, purpose: "在打卡编辑过程中选择本次阅读的书籍", targets: [
            target("BookPickerView", "搜索并选择打卡对应的书籍", "Android CheckInDialog 中选择打卡书籍", SheetCatalogAndroidEvidence.checkIn)
        ]),
        site("reading.timing-editor.book", .production, "阅读", "ReadCalendarTimingEditorSheet", "xmnote/Views/Reading/ReadCalendar/Sheets/ReadCalendarTimingEditorSheet.swift", 194, .isPresented, .customBusinessShell, nested: true, purpose: "在计时记录编辑过程中更换关联书籍", targets: [
            target("BookPickerView", "搜索并选择计时记录对应的书籍", "Android 日阅读记录编辑中的书籍选择", SheetCatalogAndroidEvidence.dailyReading)
        ]),
        site("reading.dashboard.year-summary", .production, "阅读", "ReadingDashboardView", "xmnote/Views/Reading/ReadingDashboardView.swift", 166, .isPresented, .scaffoldPairedActions, purpose: "从在读首页查看本年度完成阅读的书籍清单", targets: [
            target("ReadingYearSummarySheet", "浏览年度已读书籍并切换目标年份", "Android ReadingFragment 的年度阅读书籍区域", SheetCatalogAndroidEvidence.readingDashboard)
        ]),
        site("reading.dashboard.goal", .production, "阅读", "ReadingDashboardView", "xmnote/Views/Reading/ReadingDashboardView.swift", 173, .item, .scaffoldBottomAction, purpose: "创建或修改每日与年度阅读目标", targets: [
            target("ReadingGoalEditorSheet", "编辑目标数值、周期和启用状态", "Android ReadPlanEditActivity 的阅读计划编辑", SheetCatalogAndroidEvidence.readingGoal)
        ]),
        site("reading.heatmap.help", .production, "阅读", "ReadingHeatmapWidgetView", "xmnote/Views/Reading/ReadingHeatmapWidgetView.swift", 133, .isPresented, .scaffoldClose, purpose: "解释阅读热力图的颜色、统计口径和交互", targets: [
            target("HeatmapHelpSheetView", "查看热力图规则和相关设置入口", "Android 阅读统计与 HeatChartSettingActivity", SheetCatalogAndroidEvidence.heatmap)
        ]),
        site("reading.timer.start", .production, "阅读", "ReadingTimerView", "xmnote/Views/Reading/ReadingTimerView.swift", 75, .isPresented, .scaffoldBottomAction, purpose: "开始计时前选择书籍和起始阅读位置", targets: [
            target("ReadingTimerStartSheet", "配置本次计时书籍与起始位置并开始", "Android ReadTimingActivity 的计时启动流程", SheetCatalogAndroidEvidence.timing)
        ]),
        site("reading.timer.finish", .production, "阅读", "ReadingTimerView", "xmnote/Views/Reading/ReadingTimerView.swift", 84, .isPresented, .scaffoldBottomAction, purpose: "停止计时后补充阅读结果并保存记录", targets: [
            target("ReadingTimerFinishSheet", "确认书籍、时长、阅读位置和感想并保存", "Android ReadTimeRecordActivity 的计时记录完成流程", SheetCatalogAndroidEvidence.timingRecord)
        ]),
        site("reading.timer-finish.book", .production, "阅读", "ReadingTimerFinishSheet", "xmnote/Views/Reading/Sheets/ReadingTimerFinishSheet.swift", 188, .isPresented, .customBusinessShell, nested: true, purpose: "在结束计时确认中补选或更换书籍", targets: [
            target("BookPickerView", "搜索并选择本次计时对应的书籍", "Android ReadTimeRecordActivity 打开的选书 Sheet", SheetCatalogAndroidEvidence.timingRecord)
        ]),
        site("reading.timeline.year-month", .production, "阅读", "ReadingTimelineView", "xmnote/Views/Reading/Timeline/ReadingTimelineView.swift", 425, .isPresented, .customBusinessShell, purpose: "从阅读时间线快速跳转到指定年月", targets: [
            target("XMYearMonthPickerSheet", "选择年份和月份并刷新时间线", "Android TimelineFragment 的 YearMonthPickerBottomSheet", SheetCatalogAndroidEvidence.yearMonth)
        ])
    ]

    private static func site(
        _ id: String,
        _ origin: SheetCatalogOrigin,
        _ module: String,
        _ host: String,
        _ path: String,
        _ line: Int,
        _ presentationKind: SheetCatalogPresentationKind,
        _ family: SheetCatalogFamily,
        nested: Bool = false,
        purpose: String,
        targets: [SheetCatalogTargetDefinition],
        facts: SheetCatalogPresentationFacts? = nil
    ) -> SheetCatalogCallSite {
        let resolvedFacts = facts ?? .defaults(for: family)
        return SheetCatalogCallSite(
            id: id,
            origin: origin,
            module: module,
            host: host,
            appPurpose: purpose,
            sourcePath: path,
            sourceLine: line,
            presentationKind: presentationKind,
            family: family,
            isNested: nested,
            targets: targets.enumerated().map { index, definition in
                let targetID = "\(id).target.\(index)"
                return SheetCatalogTarget(
                    id: targetID,
                    owner: definition.owner,
                    sheetPurpose: definition.sheetPurpose,
                    androidAnalogue: definition.androidAnalogue,
                    facts: resolvedFacts,
                    productionPreview: origin == .production
                        ? SheetProductionPreviewRegistry.definition(
                            targetID: targetID,
                            owner: definition.owner,
                            module: module,
                            host: host,
                            purpose: purpose,
                            facts: resolvedFacts,
                            isNested: nested
                        )
                        : nil
                )
            }
        )
    }

    private static func target(
        _ owner: String,
        _ sheetPurpose: String,
        _ androidScene: String,
        _ androidReferences: [SheetCatalogAndroidReference]
    ) -> SheetCatalogTargetDefinition {
        SheetCatalogTargetDefinition(
            owner: owner,
            sheetPurpose: sheetPurpose,
            androidAnalogue: SheetCatalogAndroidAnalogue(
                scene: androidScene,
                references: androidReferences
            )
        )
    }
}

private enum SheetProductionPreviewRegistry {
    static func definition(
        targetID: String,
        owner: String,
        module: String,
        host: String,
        purpose: String,
        facts: SheetCatalogPresentationFacts,
        isNested: Bool
    ) -> SheetProductionPreviewDefinition {
        let requirement = dataRequirement(for: owner, module: module)
        return SheetProductionPreviewDefinition(
            targetID: targetID,
            rendererOwner: owner,
            dataRequirement: requirement,
            dataSource: dataSource(for: requirement, host: host),
            productionConfiguration: productionConfiguration(
                targetID: targetID,
                owner: owner,
                facts: facts
            ),
            currentStructure: currentStructure(
                owner: owner,
                purpose: purpose,
                isNested: isNested,
                facts: facts
            )
        )
    }

    private static func dataRequirement(
        for owner: String,
        module: String
    ) -> SheetProductionPreviewDataRequirement {
        let externalOwners = [
            "AITextResultSheet", "AIAutoTagSheet", "AIConfigurationPromptEditSheet",
            "BookCollectionCoverSearchSheet", "BookCollectionWereadImportSheet",
            "BookCollectionWereadImportPreviewSheet", "ChapterRemoteSyncSheet",
            "BackupHistorySheetView", "BackupRestoreConfirmSheet", "LocalBackup",
            "XMActivityShareSheet", "WebDAVServerFormView"
        ]
        if externalOwners.contains(where: owner.contains) {
            return .safeExternal
        }
        // 目标 View 的数据契约优先于宿主业务模块；例如内容编辑中的
        // BookPickerView 仍应展示生产书籍，而不是宿主的书摘样例。
        if owner.contains("Book") || owner.contains("Bookshelf") || owner.contains("Chapter") {
            return .books
        }
        if owner.contains("Tag") {
            return .tags
        }
        if owner.contains("Collection") || owner.contains("书单") {
            return .collections
        }
        if owner.contains("Reading") || owner.contains("ReadCalendar") || owner.contains("Heatmap") {
            return .reading
        }
        if owner.contains("Note") || module == "内容" || module == "书摘" {
            return .notes
        }
        return .none
    }

    private static func dataSource(
        for requirement: SheetProductionPreviewDataRequirement,
        host: String
    ) -> String {
        switch requirement {
        case .safeExternal:
            "当前生产数据库的业务输入 + 可取消的安全响应替身；不读取凭据、不访问远端"
        case .none:
            "复用 \(host) 的生产初始化配置与隔离偏好草稿"
        default:
            "进入目录时复制当前生产数据库；每次打开从基础快照生成独立工作副本"
        }
    }

    private static func productionConfiguration(
        targetID: String,
        owner: String,
        facts: SheetCatalogPresentationFacts
    ) -> String {
        let presentation = [
            facts.detents,
            facts.dragIndicator,
            facts.actionPlacement,
            facts.interactiveDismissal
        ].joined(separator: "；")

        guard owner.hasPrefix("BookPickerView") else {
            return presentation
        }

        let pickerConfiguration: String
        switch targetID {
        case let id where id.hasPrefix("book.collection-detail.picker"):
            pickerConfiguration = "标题“添加书籍”；本地 + 在线；多选；允许新增；顶部“加入书单”；在线结果直接返回"
        case let id where id.hasPrefix("content.related-book.picker"):
            pickerConfiguration = "标题“选择关联书籍”；仅本地；单选；预选当前关联书籍"
        case let id where id.hasPrefix("note.editor.destination"):
            pickerConfiguration = "标题“选择书籍”；仅本地；单选；允许通过嵌套搜索页新增；预选当前书籍"
        case let id where id.hasPrefix("note.excerpt.batch"):
            pickerConfiguration = "标题“移动到书籍”；仅本地；单选；不允许新增"
        case let id where id.hasPrefix("note.review-settings.destination"):
            pickerConfiguration = "标题“选择回顾书籍”；仅本地；多选；允许空结果；顶部“完成”；预选当前范围"
        case let id where id.hasPrefix("personal.data-import.book")
            || id.hasPrefix("personal.unified-import.book"):
            pickerConfiguration = "标题“映射到已有书籍”；仅本地；单选；使用导入书名作为默认查询"
        case let id where id.hasPrefix("reading.check-in.book"):
            pickerConfiguration = "标题“选择打卡书籍”；仅本地；单选；不允许新增；预选当前书籍"
        case let id where id.hasPrefix("reading.timing-editor.book"):
            pickerConfiguration = "标题“选择阅读书籍”；仅本地；单选；不允许新增；预选当前书籍"
        case let id where id.hasPrefix("reading.timer-finish.book"):
            pickerConfiguration = "标题“选择记录书籍”；仅本地；单选；允许通过嵌套搜索页新增；预选当前书籍"
        default:
            pickerConfiguration = "仅本地；单选；使用当前生产上下文"
        }
        return pickerConfiguration + "；" + presentation
    }

    private static func currentStructure(
        owner: String,
        purpose: String,
        isNested: Bool,
        facts: SheetCatalogPresentationFacts
    ) -> String {
        let nesting = isNested ? "父 Sheet 内嵌套打开" : "从生产宿主直接打开"
        return "\(owner)：\(purpose)；\(nesting)；\(facts.actionPlacement)"
    }
}
#endif
