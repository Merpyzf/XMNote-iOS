#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/Observation 维护业务场景注册表、Sheet 展示样式、固定本地/在线预选、仓储替身与结果预览
 * [OUTPUT]: 对外提供 BookSelectionTestViewModel、包含异步模拟初始选择的 BookSelectionSheetPresentationRequest、固定仓储及场景/结果预览模型，统一驱动书籍选择测试中心
 * [POS]: Debug 模块书籍选择测试页状态编排，集中收口业务映射、固定测试数据、运行配置与结果消费预览
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

enum BookSelectionScenarioGroup: String, CaseIterable, Identifiable {
    case localSingleWithCreation
    case localSingle
    case localMultipleFilter
    case mixedDirectSelection
    case onlineDirectSelection
    case componentStates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localSingleWithCreation:
            return "本地单选 + 创建"
        case .localSingle:
            return "本地单选"
        case .localMultipleFilter:
            return "本地多选筛选"
        case .mixedDirectSelection:
            return "双源直接消费"
        case .onlineDirectSelection:
            return "在线专项直接消费"
        case .componentStates:
            return "组件完整性场景"
        }
    }

    var subtitle: String {
        switch self {
        case .localSingleWithCreation:
            return "本地书架单选，并保留手动新增/嵌套搜书的补书入口"
        case .localSingle:
            return "只消费本地书结果，用于映射、导出目标或单书替换"
        case .localMultipleFilter:
            return "多选书籍范围，允许用空集合表达“全部书籍 / 未限制范围”"
        case .mixedDirectSelection:
            return "本地与在线结果共存，在线结果可不落库直接回流业务页"
        case .onlineDirectSelection:
            return "只看在线搜索结果，并直接返回补齐后的远端 payload。"
        case .componentStates:
            return "用固定数据验证已选管理、数量层级、不可重复选择和必要空态。"
        }
    }
}

enum BookSelectionScenarioPreselectionStrategy: Hashable {
    case none
    case firstLocalBook
    case firstLocalBooks(Int)
    case allLocalBooks
}

enum BookSelectionFixture: Hashable {
    case standard
    case emptyLibrary
    case onlineFailure
    case slowRemoteResolution
}

extension BookPickerSheetPresentationStyle {
    var debugTitle: String {
        switch self {
        case .currentStandard:
            return "当前标准"
        case .appleRecommended:
            return "Apple 推荐"
        }
    }

    var debugSummary: String {
        switch self {
        case .currentStandard:
            return "自定义标题栏与底部全宽确认按钮，保持现有生产书籍选择体验。"
        case .appleRecommended:
            return "系统工具栏前导关闭、尾随品牌色确认，不在底部重复放置长按钮。"
        }
    }
}

enum BookSelectionScenarioConsumer: Hashable {
    case localSingle(actionLabel: String)
    case localMultiple(emptyMeaning: String)
    case mixedSingle(actionLabel: String)
    case mixedMultiple(actionLabel: String)
    case chapterSyncPayload
    case noteInfoPayload
}

struct BookSelectionScenarioConfigurationSpec: Hashable {
    let title: String
    let scope: BookPickerScope
    let selectionMode: BookPickerSelectionMode
    let allowsCreationFlow: Bool
    let creationAction: BookPickerCreationAction
    let onlineSelectionPolicy: BookPickerOnlineSelectionPolicy
    let multipleConfirmationPolicy: BookPickerMultipleConfirmationPolicy
    let multipleConfirmationTitle: String
    let defaultQuery: String
    let onlineSources: [BookSearchSource]
    let preferredOnlineSource: BookSearchSource?
    let preselectionStrategy: BookSelectionScenarioPreselectionStrategy
    var fixture: BookSelectionFixture = .standard
    var marksFirstLocalBookUnavailable = false

    func makeConfiguration(sampleLocalBooks: [BookPickerBook]) -> BookPickerConfiguration {
        let preselectedBooks: [BookPickerBook]
        switch preselectionStrategy {
        case .none:
            preselectedBooks = []
        case .firstLocalBook:
            preselectedBooks = sampleLocalBooks.first.map { [$0] } ?? []
        case .firstLocalBooks(let count):
            preselectedBooks = Array(sampleLocalBooks.prefix(max(0, count)))
        case .allLocalBooks:
            preselectedBooks = sampleLocalBooks
        }

        let unavailableLocalBookIDs = marksFirstLocalBookUnavailable
            ? Set(sampleLocalBooks.prefix(1).map(\.id))
            : []

        return BookPickerConfiguration(
            title: title,
            scope: scope,
            selectionMode: selectionMode,
            allowsCreationFlow: allowsCreationFlow,
            creationAction: creationAction,
            onlineSelectionPolicy: onlineSelectionPolicy,
            multipleConfirmationPolicy: multipleConfirmationPolicy,
            multipleConfirmationTitle: multipleConfirmationTitle,
            defaultQuery: defaultQuery,
            preselectedBooks: preselectedBooks,
            unavailableLocalBookIDs: unavailableLocalBookIDs,
            unavailableLocalBookMessage: marksFirstLocalBookUnavailable ? "已在书单" : nil,
            onlineSources: onlineSources,
            preferredOnlineSource: preferredOnlineSource
        )
    }

    var implementationDescription: String {
        var components = [
            "scope: .\(scope.debugName)",
            "selectionMode: .\(selectionMode.debugName)",
            "allowsCreationFlow: \(allowsCreationFlow ? "true" : "false")"
        ]

        if allowsCreationFlow {
            components.append("creationAction: .\(creationAction.debugName)")
        }
        if onlineSelectionPolicy != .requireLocalCreation {
            components.append("onlineSelectionPolicy: .\(onlineSelectionPolicy.debugName)")
        }
        if multipleConfirmationPolicy != .requiresSelection {
            components.append("multipleConfirmationPolicy: .\(multipleConfirmationPolicy.debugName)")
        }
        if !multipleConfirmationTitle.isEmpty, multipleConfirmationTitle != "添加所选书籍" {
            components.append("multipleConfirmationTitle: \"\(multipleConfirmationTitle)\"")
        }
        if !defaultQuery.isEmpty {
            components.append("defaultQuery: \"\(defaultQuery)\"")
        }
        switch preselectionStrategy {
        case .none:
            break
        case .firstLocalBook:
            components.append("preselectedBooks: firstLocalBook")
        case .firstLocalBooks(let count):
            components.append("preselectedBooks: first \(count)")
        case .allLocalBooks:
            components.append("preselectedBooks: allFixtureBooks")
        }
        if marksFirstLocalBookUnavailable {
            components.append("unavailableLocalBookIDs: firstLocalBook")
        }
        if let preferredOnlineSource {
            components.append("preferredOnlineSource: .\(preferredOnlineSource.debugName)")
        }

        return "BookPickerView(\(components.joined(separator: ", ")))"
    }
}

struct BookSelectionTestScenario: Identifiable, Hashable {
    let id: String
    let title: String
    let androidEntry: String
    let group: BookSelectionScenarioGroup
    let capabilityTags: [String]
    let configurationSpec: BookSelectionScenarioConfigurationSpec
    let consumer: BookSelectionScenarioConsumer
    let runtimeHint: String?
}

/// 绑定一次测试 Sheet 的业务场景和展示样式，避免呈现期间切换选择器导致当前 Sheet 换壳。
struct BookSelectionSheetPresentationRequest: Identifiable, Hashable {
    let scenario: BookSelectionTestScenario
    let sheetPresentationStyle: BookPickerSheetPresentationStyle
    let preselectedRemoteResults: [BookSearchResult]

    var id: String {
        let remoteSelectionIdentity = preselectedRemoteResults.map(\.id).joined(separator: ",")
        return "\(scenario.id)-\(sheetPresentationStyle.rawValue)-\(remoteSelectionIdentity)"
    }
}

struct BookSelectionScenarioPreview: Hashable {
    let title: String
    let message: String
    let details: [String]
}

@Observable
final class BookSelectionTestViewModel {
    var selectedSheetPresentationStyle: BookPickerSheetPresentationStyle = .appleRecommended
    var presentedSheetRequest: BookSelectionSheetPresentationRequest?
    var sampleLocalBooks: [BookPickerBook]
    var isLoadingSampleLocalBooks = false
    var bootstrapErrorMessage: String?
    private var previewsByScenarioID: [String: BookSelectionScenarioPreview] = [:]

    private static let asynchronousConfirmationScenarioID = "mixed-resolution"

    init() {
        sampleLocalBooks = BookSelectionFixtureCatalog.localBooks
    }

    static let scenarios: [BookSelectionTestScenario] = [
        BookSelectionTestScenario(
            id: "note-edit",
            title: "书摘编辑关联书籍",
            androidEntry: "NoteEditActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "书摘编辑页已回填书籍"),
            runtimeHint: "当前 iOS 正式业务入口就是这一类配置；在测试页中可直接验证新增后回填。"
        ),
        BookSelectionTestScenario(
            id: "read-time-record",
            title: "读书计时关联书籍",
            androidEntry: "ReadTimeRecordActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "读书计时页已记录目标书籍"),
            runtimeHint: "实现能力与 Android 一致，当前通过测试中心验证，不额外新建正式业务页"
        ),
        BookSelectionTestScenario(
            id: "read-plan-edit",
            title: "读书计划关联书籍",
            androidEntry: "ReadPlanEditActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "读书计划已绑定目标书籍"),
            runtimeHint: "适合验证“书架为空 -> 新增一本书 -> 回填计划目标”的完整链路"
        ),
        BookSelectionTestScenario(
            id: "reading-continue",
            title: "继续阅读目标书",
            androidEntry: "ReadingFragment",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择继续阅读的书"),
            consumer: .localSingle(actionLabel: "继续阅读目标已切换"),
            runtimeHint: "对应 Android 统计页“继续阅读”入口"
        ),
        BookSelectionTestScenario(
            id: "floating-ball-setting",
            title: "悬浮球默认书籍",
            androidEntry: "FloatingBallSettingActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择默认书籍"),
            consumer: .localSingle(actionLabel: "悬浮球默认书籍已更新"),
            runtimeHint: "用于验证偏好设置型页面对本地单选 + 新建回填的消费方式"
        ),
        BookSelectionTestScenario(
            id: "import-book-map",
            title: "导入映射目标书",
            androidEntry: "ImportBookListFragment",
            group: .localSingle,
            capabilityTags: ["本地", "单选", "预选"],
            configurationSpec: .localSingle(title: "选择映射目标书", preselectionStrategy: .firstLocalBook),
            consumer: .localSingle(actionLabel: "导入映射目标书已回填"),
            runtimeHint: "若本地书架非空，会自动预选第一本书，便于验证 Android 的映射回显语义"
        ),
        BookSelectionTestScenario(
            id: "check-in-dialog",
            title: "打卡弹窗选择书籍",
            androidEntry: "CheckInDialog",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "打卡对象已切换"),
            runtimeHint: "纯本地单选，不提供创建入口"
        ),
        BookSelectionTestScenario(
            id: "note-export",
            title: "导出单书笔记",
            androidEntry: "NoteExportActivity",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择导出书籍"),
            consumer: .localSingle(actionLabel: "导出目标书已确定"),
            runtimeHint: "用于验证导出页对单一书籍目标的消费载荷"
        ),
        BookSelectionTestScenario(
            id: "move-notes-to-book",
            title: "批量移动笔记到书籍",
            androidEntry: "NotesFragment",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择目标书籍"),
            consumer: .localSingle(actionLabel: "移动目标书已确定"),
            runtimeHint: "只接收目标本地书，不允许从选择器里新增书籍"
        ),
        BookSelectionTestScenario(
            id: "note-widget-setting",
            title: "笔记小组件书籍范围",
            androidEntry: "NoteWidgetSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择书籍范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "清空后确认会回传空集合，用来表达“不限制到特定书籍”"
        ),
        BookSelectionTestScenario(
            id: "unprotected-widget-setting",
            title: "未加锁小组件书籍范围",
            androidEntry: "UnProtectedNoteWidgetSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择书籍范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "与普通小组件共用同一类多选过滤能力"
        ),
        BookSelectionTestScenario(
            id: "note-review-setting",
            title: "复习设置书籍范围",
            androidEntry: "NoteReviewSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择复习范围", multipleConfirmationTitle: "完成"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示未限制复习书籍范围"),
            runtimeHint: "适合验证“空选择 = 不限范围”的业务语义"
        ),
        BookSelectionTestScenario(
            id: "book-batch-export",
            title: "批量导出书籍范围",
            androidEntry: "BookBatchExportActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择导出范围", multipleConfirmationTitle: "确认导出范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "对齐 Android：空集合代表导出全部书籍"
        ),
        BookSelectionTestScenario(
            id: "note-batch-export",
            title: "批量导出笔记范围",
            androidEntry: "NoteBatchExportActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择笔记导出范围", multipleConfirmationTitle: "确认笔记范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "与书籍批量导出共享同一类“空集合 = 全部”语义"
        ),
        BookSelectionTestScenario(
            id: "paper-setting",
            title: "纸条/壁纸书籍范围",
            androidEntry: "PaperSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择展示范围", multipleConfirmationTitle: "确认展示范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示未限制书籍范围"),
            runtimeHint: "适合验证多选过滤和空选择提交"
        ),
        BookSelectionTestScenario(
            id: "relevant-list",
            title: "相关书籍直接关联",
            androidEntry: "RelevantListFragment",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "单选", "远端直返", "允许创建"],
            configurationSpec: .mixedDirectSingle(title: "选择相关书籍", defaultQuery: "三体"),
            consumer: .mixedSingle(actionLabel: "相关书籍已直接回流"),
            runtimeHint: "在线结果会直接返回远端 payload，不要求先创建本地书"
        ),
        BookSelectionTestScenario(
            id: "read-timing-relevant",
            title: "读书计时相关书籍",
            androidEntry: "ReadTimingFragment",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "单选", "远端直返", "允许创建"],
            configurationSpec: .mixedDirectSingle(title: "选择相关书籍", defaultQuery: "活着"),
            consumer: .mixedSingle(actionLabel: "读书计时相关书籍已更新"),
            runtimeHint: "用于验证与 Android 一致的“在线搜到就能直接消费”能力"
        ),
        BookSelectionTestScenario(
            id: "edit-collection",
            title: "编辑收藏书籍集合",
            androidEntry: "EditCollectionActivity",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "多选", "混合选择", "允许创建"],
            configurationSpec: .mixedDirectMultiple(title: "添加所选书籍"),
            consumer: .mixedMultiple(actionLabel: "收藏书籍集合已更新"),
            runtimeHint: "支持本地书与在线结果混合选择，确认时会统一返回混合集合"
        ),
        BookSelectionTestScenario(
            id: "chapter-manager",
            title: "章节同步搜书",
            androidEntry: "ChapterManagerActivity",
            group: .onlineDirectSelection,
            capabilityTags: ["在线", "单选", "远端直返", "默认关键词"],
            configurationSpec: .chapterSync,
            consumer: .chapterSyncPayload,
            runtimeHint: "直接展示章节同步所需的远端 payload，不要求先创建本地书"
        ),
        BookSelectionTestScenario(
            id: "note-manager",
            title: "补全书籍信息搜书",
            androidEntry: "NoteManagerActivity",
            group: .onlineDirectSelection,
            capabilityTags: ["在线", "单选", "远端直返", "默认关键词"],
            configurationSpec: .noteInfoSync,
            consumer: .noteInfoPayload,
            runtimeHint: "用于验证补全书籍信息时的在线结果直返能力。"
        ),
        BookSelectionTestScenario(
            id: "multiple-required-empty",
            title: "多选必须选择",
            androidEntry: "BookPicker component state",
            group: .componentStates,
            capabilityTags: ["本地", "多选", "零选择禁用"],
            configurationSpec: .localMultipleRequired(title: "选择书籍", preselectionStrategy: .none),
            consumer: .localMultiple(emptyMeaning: "必须选择场景不应返回空集合"),
            runtimeHint: "零选择时副标题显示“请选择书籍”，底部“完成”保持可见但不可提交。"
        ),
        BookSelectionTestScenario(
            id: "selected-manager-one",
            title: "已选 1 本与取消至空",
            androidEntry: "BookPicker selected manager",
            group: .componentStates,
            capabilityTags: ["预选 1 本", "已选管理", "取消至空"],
            configurationSpec: .localMultipleRequired(
                title: "选择书籍",
                preselectionStrategy: .firstLocalBooks(1)
            ),
            consumer: .localMultiple(emptyMeaning: "必须选择场景不应返回空集合"),
            runtimeHint: "点击普通副标题进入管理 Sheet；取消唯一一本后可验证空态和“继续选择”。"
        ),
        BookSelectionTestScenario(
            id: "selected-manager-multiple",
            title: "多本已选与取消部分",
            androidEntry: "BookPicker selected manager",
            group: .componentStates,
            capabilityTags: ["预选 3 本", "取消部分", "内层下滑关闭"],
            configurationSpec: .localMultipleRequired(
                title: "选择书籍",
                preselectionStrategy: .firstLocalBooks(3)
            ),
            consumer: .localMultiple(emptyMeaning: "必须选择场景不应返回空集合"),
            runtimeHint: "用于验证管理 Sheet 修改共享草稿、下滑关闭后外层数量保持同步。"
        ),
        BookSelectionTestScenario(
            id: "selected-manager-many",
            title: "大量已选与已选搜索",
            androidEntry: "BookPicker selected manager",
            group: .componentStates,
            capabilityTags: ["大量预选", "搜索已选书籍", "选择顺序"],
            configurationSpec: .localMultipleRequired(
                title: "选择书籍",
                preselectionStrategy: .allLocalBooks
            ),
            consumer: .localMultiple(emptyMeaning: "必须选择场景不应返回空集合"),
            runtimeHint: "固定预选全部样本，验证管理效率、搜索和原始选择顺序。"
        ),
        BookSelectionTestScenario(
            id: "mixed-resolution",
            title: "本地与在线混合解析",
            androidEntry: "BookPicker mixed resolution",
            group: .componentStates,
            capabilityTags: ["本地+在线", "混合多选", "在线解析中"],
            configurationSpec: .mixedDirectMultiple(
                title: "选择书籍",
                preselectionStrategy: .firstLocalBooks(2),
                fixture: .slowRemoteResolution
            ),
            consumer: .mixedMultiple(actionLabel: "混合选择已提交"),
            runtimeHint: "通过顶部快捷入口打开时会固定预选本地与在线结果；确认后必然进入 2.5 秒解析，可观察确认按钮原地切换为菊花。"
        ),
        BookSelectionTestScenario(
            id: "collection-unavailable",
            title: "书单已有项不可重复选择",
            androidEntry: "BookCollectionDetailView",
            group: .componentStates,
            capabilityTags: ["多选", "已在书单", "不可重复"],
            configurationSpec: .collectionUnavailable,
            consumer: .localMultiple(emptyMeaning: "必须选择场景不应返回空集合"),
            runtimeHint: "第一本固定显示“已在书单”，不计入数量、不进入管理 Sheet，也不可再次选择。"
        ),
        BookSelectionTestScenario(
            id: "empty-library",
            title: "空书库",
            androidEntry: "BookPicker empty library",
            group: .componentStates,
            capabilityTags: ["空数据", "单选", "允许创建"],
            configurationSpec: .emptyLibrary,
            consumer: .localSingle(actionLabel: "空书库场景已回填"),
            runtimeHint: "固定仓储返回空数组，用于验证空态和新增入口。"
        ),
        BookSelectionTestScenario(
            id: "local-no-results",
            title: "本地搜索无结果",
            androidEntry: "BookPicker no results",
            group: .componentStates,
            capabilityTags: ["搜索", "无结果", "本地"],
            configurationSpec: .localNoResults,
            consumer: .localSingle(actionLabel: "搜索结果已回填"),
            runtimeHint: "以固定无匹配关键词打开，验证搜索无结果状态。"
        ),
        BookSelectionTestScenario(
            id: "online-failure",
            title: "在线搜索失败",
            androidEntry: "BookPicker online failure",
            group: .componentStates,
            capabilityTags: ["在线", "失败", "重试"],
            configurationSpec: .onlineFailure,
            consumer: .mixedSingle(actionLabel: "在线结果已回填"),
            runtimeHint: "固定仓储稳定抛出失败，用于验证错误说明和重试入口。"
        )
    ]

    var scenarioCount: Int {
        Self.scenarios.count
    }

    /// 读取本地书架样本，供预选和调试页概览使用；读取失败不阻断测试页打开。
    func loadSampleLocalBooks(using repository: any BookPickerRepositoryProtocol) async {
        guard !isLoadingSampleLocalBooks, sampleLocalBooks.isEmpty else { return }
        isLoadingSampleLocalBooks = true
        defer { isLoadingSampleLocalBooks = false }

        do {
            sampleLocalBooks = try await repository.fetchPickerBooks(matching: "")
            bootstrapErrorMessage = nil
        } catch {
            sampleLocalBooks = []
            bootstrapErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 返回某个 Android 场景在当前测试中心中的运行配置。
    func configuration(for scenario: BookSelectionTestScenario) -> BookPickerConfiguration {
        scenario.configurationSpec.makeConfiguration(sampleLocalBooks: sampleLocalBooks)
    }

    /// 为每次场景运行创建独立固定仓储，保证选择与错误状态不受真实数据或前一次运行影响。
    func fixtureRepository(for scenario: BookSelectionTestScenario) -> BookSelectionFixtureRepository {
        BookSelectionFixtureRepository(fixture: scenario.configurationSpec.fixture)
    }

    func scenarios(in group: BookSelectionScenarioGroup) -> [BookSelectionTestScenario] {
        Self.scenarios.filter { $0.group == group }
    }

    /// 按当前选择的 Sheet 展示样式打开业务场景，并冻结这次呈现的样式值。
    func open(_ scenario: BookSelectionTestScenario) {
        presentedSheetRequest = BookSelectionSheetPresentationRequest(
            scenario: scenario,
            sheetPresentationStyle: selectedSheetPresentationStyle,
            preselectedRemoteResults: []
        )
    }

    /// 打开带固定延迟远端解析的多选场景，用于观察顶部确认按钮的异步反馈。
    func openAsynchronousConfirmationComparison() {
        guard let asynchronousConfirmationScenario,
              let remoteResult = BookSelectionFixtureCatalog.remoteResults.first else {
            return
        }
        presentedSheetRequest = BookSelectionSheetPresentationRequest(
            scenario: asynchronousConfirmationScenario,
            sheetPresentationStyle: selectedSheetPresentationStyle,
            preselectedRemoteResults: [remoteResult]
        )
    }

    /// 清理已结束的 Sheet 请求，保证下一次呈现创建独立仓储和选择会话。
    func clearPresentedSheetRequest() {
        presentedSheetRequest = nil
    }

    /// 收口某个场景最近一次运行结果，并生成对应的消费预览面板。
    func record(_ result: BookPickerResult, for scenario: BookSelectionTestScenario) {
        previewsByScenarioID[scenario.id] = makePreview(result: result, scenario: scenario)
    }

    func preview(for scenario: BookSelectionTestScenario) -> BookSelectionScenarioPreview {
        previewsByScenarioID[scenario.id] ?? placeholderPreview(for: scenario)
    }

    var asynchronousConfirmationScenario: BookSelectionTestScenario? {
        Self.scenarios.first { $0.id == Self.asynchronousConfirmationScenarioID }
    }

    var localBookSummary: String {
        if isLoadingSampleLocalBooks {
            return "正在读取本地书架样本…"
        }
        if sampleLocalBooks.isEmpty {
            return "当前未检测到本地书籍，相关场景仍可打开，但预选/回填会从空书架起步"
        }
        return "已加载 \(sampleLocalBooks.count) 本固定样本书；本页不会读取真实书架或请求外部网络。"
    }

    private func placeholderPreview(for scenario: BookSelectionTestScenario) -> BookSelectionScenarioPreview {
        let message: String
        switch scenario.consumer {
        case .localSingle:
            message = "尚未运行。打开后会回传一条本地书选择结果。"
        case .localMultiple(let emptyMeaning):
            message = "尚未运行。空集合确认后会显示“\(emptyMeaning)”。"
        case .mixedSingle:
            message = "尚未运行。当前场景支持本地书与在线结果二选一直接回流。"
        case .mixedMultiple:
            message = "尚未运行。当前场景支持本地书与在线结果混合多选。"
        case .chapterSyncPayload:
            message = "尚未运行。打开后会展示章节同步所消费的远端 payload。"
        case .noteInfoPayload:
            message = "尚未运行。打开后会展示补全书籍信息所消费的远端 payload。"
        }

        return BookSelectionScenarioPreview(
            title: "结果预览",
            message: message,
            details: scenario.runtimeHint.map { [$0] } ?? []
        )
    }

    private func makePreview(
        result: BookPickerResult,
        scenario: BookSelectionTestScenario
    ) -> BookSelectionScenarioPreview {
        switch result {
        case .cancelled:
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "本次操作已取消，没有新的回流结果",
                details: []
            )
        case .addFlowRequested:
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "当前实现请求跳转到独立新增书籍页",
                details: []
            )
        case .editorRequested:
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "当前实现请求打开独立书籍编辑任务",
                details: []
            )
        case .single(let selection):
            return makeSelectionPreview(selections: [selection], scenario: scenario)
        case .multiple(let selections):
            return makeSelectionPreview(selections: selections, scenario: scenario)
        }
    }

    private func makeSelectionPreview(
        selections: [BookPickerSelection],
        scenario: BookSelectionTestScenario
    ) -> BookSelectionScenarioPreview {
        switch scenario.consumer {
        case .localSingle(let actionLabel):
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: actionLabel,
                details: selections.map(selectionLine)
            )
        case .localMultiple(let emptyMeaning):
            if selections.isEmpty {
                return BookSelectionScenarioPreview(
                    title: "结果预览",
                    message: emptyMeaning,
                    details: ["返回空数组，业务侧据此解释为“全部 / 未限制”"]
                )
            }

            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "已确认 \(selections.count) 本本地书",
                details: selections.map(selectionLine)
            )
        case .mixedSingle(let actionLabel):
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: actionLabel,
                details: selections.flatMap(mixedSelectionLines)
            )
        case .mixedMultiple(let actionLabel):
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "\(actionLabel)（共 \(selections.count) 项）",
                details: selections.flatMap(mixedSelectionLines)
            )
        case .chapterSyncPayload:
            return chapterPayloadPreview(from: selections.first)
        case .noteInfoPayload:
            return noteInfoPayloadPreview(from: selections.first)
        }
    }

    private func chapterPayloadPreview(from selection: BookPickerSelection?) -> BookSelectionScenarioPreview {
        guard case .remote(let remoteSelection)? = selection else {
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "章节同步需要远端结果 payload，当前返回值不符合预期",
                details: selection.map { [selectionLine($0)] } ?? []
            )
        }

        return BookSelectionScenarioPreview(
            title: "章节同步 Payload",
            message: "已拿到可直接用于章节同步的远端结果",
            details: [
                "来源：\(remoteSelection.result.source.title)",
                "标题：\(preferredRemoteTitle(remoteSelection))",
                "作者：\(preferredRemoteAuthor(remoteSelection))",
                detailLine(label: "详情页", value: remoteSelection.result.detailPageURL),
                detailLine(label: "豆瓣 ID", value: remoteSelection.result.doubanId.map(String.init))
            ]
            .compactMap { $0 }
        )
    }

    private func noteInfoPayloadPreview(from selection: BookPickerSelection?) -> BookSelectionScenarioPreview {
        guard case .remote(let remoteSelection)? = selection else {
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "补全书籍信息需要远端结果 payload，当前返回值不符合预期",
                details: selection.map { [selectionLine($0)] } ?? []
            )
        }

        return BookSelectionScenarioPreview(
            title: "补全书籍信息 Payload",
            message: "已拿到可直接补全录入页的远端结果",
            details: [
                "来源：\(remoteSelection.result.source.title)",
                "标题：\(preferredRemoteTitle(remoteSelection))",
                "作者：\(preferredRemoteAuthor(remoteSelection))",
                detailLine(label: "出版社", value: nonEmpty(remoteSelection.seed.press)),
                detailLine(label: "ISBN", value: nonEmpty(remoteSelection.seed.isbn)),
                detailLine(label: "出版日期", value: nonEmpty(remoteSelection.seed.pubDate))
            ]
            .compactMap { $0 }
        )
    }

    private func mixedSelectionLines(_ selection: BookPickerSelection) -> [String] {
        switch selection {
        case .local(let book):
            return ["本地书：\(book.title) / \(book.author) / id \(book.id)"]
        case .remote(let remoteSelection):
            return [
                "在线书：\(preferredRemoteTitle(remoteSelection)) / \(remoteSelection.result.source.title)",
                detailLine(label: "作者", value: nonEmpty(preferredRemoteAuthor(remoteSelection))),
                detailLine(label: "详情页", value: remoteSelection.result.detailPageURL)
            ]
            .compactMap { $0 }
        }
    }

    private func selectionLine(_ selection: BookPickerSelection) -> String {
        switch selection {
        case .local(let book):
            return "本地书：\(book.title) / \(book.author) / id \(book.id)"
        case .remote(let remoteSelection):
            return "在线书：\(preferredRemoteTitle(remoteSelection)) / \(remoteSelection.result.source.title)"
        }
    }

    private func preferredRemoteTitle(_ selection: BookPickerRemoteSelection) -> String {
        nonEmpty(selection.seed.title) ?? selection.result.title
    }

    private func preferredRemoteAuthor(_ selection: BookPickerRemoteSelection) -> String {
        nonEmpty(selection.seed.author) ?? selection.result.author
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func detailLine(label: String, value: String?) -> String? {
        guard let value = nonEmpty(value ?? "") else { return nil }
        return "\(label)：\(value)"
    }
}

private extension BookSelectionScenarioConfigurationSpec {
    static func localSingleCreate(title: String) -> Self {
        Self(
            title: title,
            scope: .local,
            selectionMode: .single,
            allowsCreationFlow: true,
            creationAction: .nestedSearchPage,
            onlineSelectionPolicy: .requireLocalCreation,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "添加所选书籍",
            defaultQuery: "",
            onlineSources: BookSearchSource.allCases,
            preferredOnlineSource: nil,
            preselectionStrategy: .none
        )
    }

    static func localSingle(
        title: String,
        preselectionStrategy: BookSelectionScenarioPreselectionStrategy = .none
    ) -> Self {
        Self(
            title: title,
            scope: .local,
            selectionMode: .single,
            allowsCreationFlow: false,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .requireLocalCreation,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "添加所选书籍",
            defaultQuery: "",
            onlineSources: BookSearchSource.allCases,
            preferredOnlineSource: nil,
            preselectionStrategy: preselectionStrategy
        )
    }

    static func localMultipleFilter(
        title: String,
        multipleConfirmationTitle: String = "确认书籍范围"
    ) -> Self {
        Self(
            title: title,
            scope: .local,
            selectionMode: .multiple,
            allowsCreationFlow: false,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .requireLocalCreation,
            multipleConfirmationPolicy: .allowsEmptyResult,
            multipleConfirmationTitle: multipleConfirmationTitle,
            defaultQuery: "",
            onlineSources: BookSearchSource.allCases,
            preferredOnlineSource: nil,
            preselectionStrategy: .none
        )
    }

    static func localMultipleRequired(
        title: String,
        preselectionStrategy: BookSelectionScenarioPreselectionStrategy,
        multipleConfirmationTitle: String = "完成"
    ) -> Self {
        Self(
            title: title,
            scope: .local,
            selectionMode: .multiple,
            allowsCreationFlow: false,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .requireLocalCreation,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: multipleConfirmationTitle,
            defaultQuery: "",
            onlineSources: BookSearchSource.productionCases,
            preferredOnlineSource: nil,
            preselectionStrategy: preselectionStrategy
        )
    }

    static func mixedDirectSingle(title: String, defaultQuery: String) -> Self {
        Self(
            title: title,
            scope: .both,
            selectionMode: .single,
            allowsCreationFlow: true,
            creationAction: .nestedSearchPage,
            onlineSelectionPolicy: .returnRemoteSelection,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "添加所选书籍",
            defaultQuery: defaultQuery,
            onlineSources: BookSearchSource.allCases,
            preferredOnlineSource: .douban,
            preselectionStrategy: .none
        )
    }

    static func mixedDirectMultiple(
        title: String,
        preselectionStrategy: BookSelectionScenarioPreselectionStrategy = .none,
        fixture: BookSelectionFixture = .standard
    ) -> Self {
        var specification = Self(
            title: title,
            scope: .both,
            selectionMode: .multiple,
            allowsCreationFlow: true,
            creationAction: .nestedSearchPage,
            onlineSelectionPolicy: .returnRemoteSelection,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: title,
            defaultQuery: "三体",
            onlineSources: BookSearchSource.allCases,
            preferredOnlineSource: .douban,
            preselectionStrategy: preselectionStrategy
        )
        specification.fixture = fixture
        return specification
    }

    static var collectionUnavailable: Self {
        var specification = localMultipleRequired(
            title: "添加书籍",
            preselectionStrategy: .none,
            multipleConfirmationTitle: "加入书单"
        )
        specification.marksFirstLocalBookUnavailable = true
        return specification
    }

    static var emptyLibrary: Self {
        var specification = localSingleCreate(title: "选择书籍")
        specification.fixture = .emptyLibrary
        return specification
    }

    static var localNoResults: Self {
        Self(
            title: "选择书籍",
            scope: .local,
            selectionMode: .single,
            allowsCreationFlow: false,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .requireLocalCreation,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "完成",
            defaultQuery: "不存在的书",
            onlineSources: BookSearchSource.productionCases,
            preferredOnlineSource: nil,
            preselectionStrategy: .none
        )
    }

    static var onlineFailure: Self {
        var specification = Self(
            title: "在线选择书籍",
            scope: .online,
            selectionMode: .single,
            allowsCreationFlow: false,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .returnRemoteSelection,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "完成",
            defaultQuery: "失败场景",
            onlineSources: [.wenqu],
            preferredOnlineSource: .wenqu,
            preselectionStrategy: .none
        )
        specification.fixture = .onlineFailure
        return specification
    }

    static let chapterSync = Self(
        title: "搜索可同步章节的书",
        scope: .online,
        selectionMode: .single,
        allowsCreationFlow: false,
        creationAction: .inlineManualEditor,
        onlineSelectionPolicy: .returnRemoteSelection,
        multipleConfirmationPolicy: .requiresSelection,
        multipleConfirmationTitle: "添加所选书籍",
        defaultQuery: "诡秘之主",
        onlineSources: [.qidian, .zongHeng, .fanqie, .jjwxc, .cp, .wenqu],
        preferredOnlineSource: .qidian,
        preselectionStrategy: .none
    )

    static let noteInfoSync = Self(
        title: "搜索补全书籍信息",
        scope: .online,
        selectionMode: .single,
        allowsCreationFlow: false,
        creationAction: .inlineManualEditor,
        onlineSelectionPolicy: .returnRemoteSelection,
        multipleConfirmationPolicy: .requiresSelection,
        multipleConfirmationTitle: "添加所选书籍",
        defaultQuery: "三体",
        onlineSources: [.douban, .wenqu],
        preferredOnlineSource: .douban,
        preselectionStrategy: .none
    )
}

private extension BookPickerScope {
    var debugName: String {
        switch self {
        case .local:
            return "local"
        case .online:
            return "online"
        case .both:
            return "both"
        }
    }
}

private extension BookPickerSelectionMode {
    var debugName: String {
        switch self {
        case .single:
            return "single"
        case .multiple:
            return "multiple"
        }
    }
}

private extension BookPickerCreationAction {
    var debugName: String {
        switch self {
        case .inlineManualEditor:
            return "inlineManualEditor"
        case .separateSearchPage:
            return "separateSearchPage"
        case .nestedSearchPage:
            return "nestedSearchPage"
        }
    }
}

private extension BookPickerOnlineSelectionPolicy {
    var debugName: String {
        switch self {
        case .requireLocalCreation:
            return "requireLocalCreation"
        case .returnRemoteSelection:
            return "returnRemoteSelection"
        }
    }
}

private extension BookPickerMultipleConfirmationPolicy {
    var debugName: String {
        switch self {
        case .requiresSelection:
            return "requiresSelection"
        case .allowsEmptyResult:
            return "allowsEmptyResult"
        }
    }
}

private extension BookSearchSource {
    var debugName: String {
        switch self {
        case .wenqu:
            return "wenqu"
        case .qidian:
            return "qidian"
        case .zongHeng:
            return "zongHeng"
        case .jjwxc:
            return "jjwxc"
        case .fanqie:
            return "fanqie"
        case .cp:
            return "cp"
        case .douban:
            return "douban"
        }
    }
}

/// 测试中心固定数据目录，覆盖大量已选、混合来源和常见关键词，不访问真实书架与图片网络。
private enum BookSelectionFixtureCatalog {
    static let localBooks: [BookPickerBook] = [
        BookPickerBook(id: 10_001, title: "三体", author: "刘慈欣", press: "重庆出版社"),
        BookPickerBook(id: 10_002, title: "活着", author: "余华", press: "作家出版社"),
        BookPickerBook(id: 10_003, title: "百年孤独", author: "加西亚·马尔克斯", press: "南海出版公司"),
        BookPickerBook(id: 10_004, title: "局外人", author: "阿尔贝·加缪", press: "上海译文出版社"),
        BookPickerBook(id: 10_005, title: "月亮与六便士", author: "毛姆", press: "译林出版社"),
        BookPickerBook(id: 10_006, title: "人类简史", author: "尤瓦尔·赫拉利", press: "中信出版社"),
        BookPickerBook(id: 10_007, title: "置身事内", author: "兰小欢", press: "上海人民出版社"),
        BookPickerBook(id: 10_008, title: "献给阿尔吉侬的花束", author: "丹尼尔·凯斯", press: "河南文艺出版社"),
        BookPickerBook(id: 10_009, title: "悉达多", author: "赫尔曼·黑塞", press: "天津人民出版社"),
        BookPickerBook(id: 10_010, title: "刀锋", author: "毛姆", press: "上海译文出版社"),
        BookPickerBook(id: 10_011, title: "围城", author: "钱钟书", press: "人民文学出版社"),
        BookPickerBook(id: 10_012, title: "史蒂夫·乔布斯传", author: "沃尔特·艾萨克森", press: "中信出版社"),
        BookPickerBook(id: 10_013, title: "沉默的大多数", author: "王小波", press: "北京十月文艺出版社"),
        BookPickerBook(id: 10_014, title: "可能性的艺术", author: "刘瑜", press: "广西师范大学出版社"),
        BookPickerBook(id: 10_015, title: "金字塔原理", author: "芭芭拉·明托", press: "南海出版公司"),
        BookPickerBook(id: 10_016, title: "思考，快与慢", author: "丹尼尔·卡尼曼", press: "中信出版社"),
        BookPickerBook(id: 10_017, title: "被讨厌的勇气", author: "岸见一郎", press: "机械工业出版社"),
        BookPickerBook(id: 10_018, title: "非暴力沟通", author: "马歇尔·卢森堡", press: "华夏出版社")
    ]

    static let remoteResults: [BookSearchResult] = [
        makeRemoteResult(
            id: "fixture-three-body",
            source: .douban,
            title: "三体全集",
            author: "刘慈欣",
            press: "重庆出版社",
            isbn: "9787536692930"
        ),
        makeRemoteResult(
            id: "fixture-to-live",
            source: .wenqu,
            title: "活着",
            author: "余华",
            press: "北京十月文艺出版社",
            isbn: "9787530215593"
        ),
        makeRemoteResult(
            id: "fixture-lord-mysteries",
            source: .qidian,
            title: "诡秘之主",
            author: "爱潜水的乌贼",
            press: "安徽文艺出版社",
            isbn: ""
        )
    ]

    private static func makeRemoteResult(
        id: String,
        source: BookSearchSource,
        title: String,
        author: String,
        press: String,
        isbn: String
    ) -> BookSearchResult {
        let seed = BookEditorSeed(
            searchSource: source,
            title: title,
            rawTitle: title,
            author: author,
            authorIntro: "",
            translator: "",
            press: press,
            isbn: isbn,
            pubDate: "2026-01",
            summary: "测试中心固定远端书籍信息。",
            catalog: "",
            coverURL: "",
            doubanId: nil,
            totalPages: nil,
            totalWordCount: nil,
            preferredSourceName: source.title,
            preferredBookType: nil,
            preferredProgressUnit: nil
        )
        return BookSearchResult(
            id: id,
            source: source,
            title: title,
            author: author,
            coverURL: "",
            subtitle: press,
            summary: seed.summary,
            translator: "",
            press: press,
            isbn: isbn,
            pubDate: seed.pubDate,
            doubanId: nil,
            totalPages: nil,
            totalWordCount: nil,
            seed: seed,
            detailPageURL: nil
        )
    }
}

/// 书籍选择测试页的本地/在线双协议替身，以场景枚举稳定控制空态、失败和解析时长。
final class BookSelectionFixtureRepository: BookPickerRepositoryProtocol, BookSearchRepositoryProtocol {
    private let fixture: BookSelectionFixture
    private var recentQueries: [String] = []
    private var searchSettings = BookSearchSettings.default

    init(fixture: BookSelectionFixture) {
        self.fixture = fixture
    }

    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook] {
        guard fixture != .emptyLibrary else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return BookSelectionFixtureCatalog.localBooks }
        return BookSelectionFixtureCatalog.localBooks.filter { book in
            book.title.localizedCaseInsensitiveContains(normalizedQuery)
                || book.author.localizedCaseInsensitiveContains(normalizedQuery)
                || book.press.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook? {
        BookSelectionFixtureCatalog.localBooks.first { $0.id == bookId }
    }

    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult] {
        if fixture == .onlineFailure {
            throw BookSearchError.remoteService(message: "测试中心固定的在线失败状态")
        }
        let normalizedQuery = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { throw BookSearchError.emptyKeyword }
        return BookSelectionFixtureCatalog.remoteResults.filter { result in
            result.title.localizedCaseInsensitiveContains(normalizedQuery)
                || result.author.localizedCaseInsensitiveContains(normalizedQuery)
                || result.isbn.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        if fixture == .slowRemoteResolution {
            try await Task.sleep(nanoseconds: 2_500_000_000)
            try Task.checkCancellation()
        }
        if let seed = result.seed {
            return seed
        }
        throw BookSearchError.remoteService(message: "固定结果缺少编辑种子")
    }

    func fetchRecentQueries() -> [String] {
        recentQueries
    }

    func saveRecentQuery(_ query: String) {
        recentQueries.removeAll { $0 == query }
        recentQueries.insert(query, at: 0)
    }

    func removeRecentQuery(_ query: String) {
        recentQueries.removeAll { $0 == query }
    }

    func clearRecentQueries() {
        recentQueries.removeAll()
    }

    func fetchSearchSettings() -> BookSearchSettings {
        searchSettings
    }

    func saveSearchSettings(_ settings: BookSearchSettings) {
        searchSettings = settings
    }
}
#endif
