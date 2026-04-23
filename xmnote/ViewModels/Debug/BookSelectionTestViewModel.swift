#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/Observation 维护 Android 书籍选择场景注册表、调试结果预览与本地书样本上下文
 * [OUTPUT]: 对外提供 BookSelectionTestViewModel 及其场景/分组/结果预览模型，统一驱动书籍选择测试中心
 * [POS]: Debug 模块书籍选择测试页状态编排，集中收口 Android 场景映射、运行配置与结果消费预览
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
        }
    }

    var subtitle: String {
        switch self {
        case .localSingleWithCreation:
            return "本地书架单选，并保留手动新增/嵌套搜书的补书入口。"
        case .localSingle:
            return "只消费本地书结果，用于映射、导出目标或单书替换。"
        case .localMultipleFilter:
            return "多选书籍范围，允许用空集合表达“全部书籍 / 未限制范围”。"
        case .mixedDirectSelection:
            return "本地与在线结果共存，在线结果可不落库直接回流业务页。"
        case .onlineDirectSelection:
            return "只看在线搜索结果，并直接返回补齐后的远端 payload。"
        }
    }
}

enum BookSelectionScenarioPreselectionStrategy: Hashable {
    case none
    case firstLocalBook
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

    func makeConfiguration(sampleLocalBooks: [BookPickerBook]) -> BookPickerConfiguration {
        let preselectedBooks: [BookPickerBook]
        switch preselectionStrategy {
        case .none:
            preselectedBooks = []
        case .firstLocalBook:
            preselectedBooks = sampleLocalBooks.first.map { [$0] } ?? []
        }

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
        if preselectionStrategy == .firstLocalBook {
            components.append("preselectedBooks: firstLocalBook")
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

struct BookSelectionScenarioPreview: Hashable {
    let title: String
    let message: String
    let details: [String]
}

@Observable
final class BookSelectionTestViewModel {
    var presentedScenario: BookSelectionTestScenario?
    var sampleLocalBooks: [BookPickerBook] = []
    var isLoadingSampleLocalBooks = false
    var bootstrapErrorMessage: String?
    private var previewsByScenarioID: [String: BookSelectionScenarioPreview] = [:]

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
            runtimeHint: "实现能力与 Android 一致，当前通过测试中心验证，不额外新建正式业务页。"
        ),
        BookSelectionTestScenario(
            id: "read-plan-edit",
            title: "读书计划关联书籍",
            androidEntry: "ReadPlanEditActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "读书计划已绑定目标书籍"),
            runtimeHint: "适合验证“书架为空 -> 新增一本书 -> 回填计划目标”的完整链路。"
        ),
        BookSelectionTestScenario(
            id: "reading-continue",
            title: "继续阅读目标书",
            androidEntry: "ReadingFragment",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择继续阅读的书"),
            consumer: .localSingle(actionLabel: "继续阅读目标已切换"),
            runtimeHint: "对应 Android 统计页“继续阅读”入口。"
        ),
        BookSelectionTestScenario(
            id: "floating-ball-setting",
            title: "悬浮球默认书籍",
            androidEntry: "FloatingBallSettingActivity",
            group: .localSingleWithCreation,
            capabilityTags: ["本地", "单选", "允许创建"],
            configurationSpec: .localSingleCreate(title: "选择默认书籍"),
            consumer: .localSingle(actionLabel: "悬浮球默认书籍已更新"),
            runtimeHint: "用于验证偏好设置型页面对本地单选 + 新建回填的消费方式。"
        ),
        BookSelectionTestScenario(
            id: "import-book-map",
            title: "导入映射目标书",
            androidEntry: "ImportBookListFragment",
            group: .localSingle,
            capabilityTags: ["本地", "单选", "预选"],
            configurationSpec: .localSingle(title: "选择映射目标书", preselectionStrategy: .firstLocalBook),
            consumer: .localSingle(actionLabel: "导入映射目标书已回填"),
            runtimeHint: "若本地书架非空，会自动预选第一本书，便于验证 Android 的映射回显语义。"
        ),
        BookSelectionTestScenario(
            id: "check-in-dialog",
            title: "打卡弹窗选择书籍",
            androidEntry: "CheckInDialog",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择书籍"),
            consumer: .localSingle(actionLabel: "打卡对象已切换"),
            runtimeHint: "纯本地单选，不提供创建入口。"
        ),
        BookSelectionTestScenario(
            id: "note-export",
            title: "导出单书笔记",
            androidEntry: "NoteExportActivity",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择导出书籍"),
            consumer: .localSingle(actionLabel: "导出目标书已确定"),
            runtimeHint: "用于验证导出页对单一书籍目标的消费载荷。"
        ),
        BookSelectionTestScenario(
            id: "move-notes-to-book",
            title: "批量移动笔记到书籍",
            androidEntry: "NotesFragment",
            group: .localSingle,
            capabilityTags: ["本地", "单选"],
            configurationSpec: .localSingle(title: "选择目标书籍"),
            consumer: .localSingle(actionLabel: "移动目标书已确定"),
            runtimeHint: "只接收目标本地书，不允许从选择器里新增书籍。"
        ),
        BookSelectionTestScenario(
            id: "note-widget-setting",
            title: "笔记小组件书籍范围",
            androidEntry: "NoteWidgetSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择书籍范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "清空后确认会回传空集合，用来表达“不限制到特定书籍”。"
        ),
        BookSelectionTestScenario(
            id: "unprotected-widget-setting",
            title: "未加锁小组件书籍范围",
            androidEntry: "UnProtectedNoteWidgetSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择书籍范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "与普通小组件共用同一类多选过滤能力。"
        ),
        BookSelectionTestScenario(
            id: "note-review-setting",
            title: "复习设置书籍范围",
            androidEntry: "NoteReviewSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择复习范围", multipleConfirmationTitle: "确认复习范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示未限制复习书籍范围"),
            runtimeHint: "适合验证“空选择 = 不限范围”的业务语义。"
        ),
        BookSelectionTestScenario(
            id: "book-batch-export",
            title: "批量导出书籍范围",
            androidEntry: "BookBatchExportActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择导出范围", multipleConfirmationTitle: "确认导出范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "对齐 Android：空集合代表导出全部书籍。"
        ),
        BookSelectionTestScenario(
            id: "note-batch-export",
            title: "批量导出笔记范围",
            androidEntry: "NoteBatchExportActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择笔记导出范围", multipleConfirmationTitle: "确认笔记范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示全部书籍"),
            runtimeHint: "与书籍批量导出共享同一类“空集合 = 全部”语义。"
        ),
        BookSelectionTestScenario(
            id: "paper-setting",
            title: "纸条/壁纸书籍范围",
            androidEntry: "PaperSettingActivity",
            group: .localMultipleFilter,
            capabilityTags: ["本地", "多选", "空集合可确认"],
            configurationSpec: .localMultipleFilter(title: "选择展示范围", multipleConfirmationTitle: "确认展示范围"),
            consumer: .localMultiple(emptyMeaning: "当前视图表示未限制书籍范围"),
            runtimeHint: "适合验证多选过滤和空选择提交。"
        ),
        BookSelectionTestScenario(
            id: "relevant-list",
            title: "相关书籍直接关联",
            androidEntry: "RelevantListFragment",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "单选", "远端直返", "允许创建"],
            configurationSpec: .mixedDirectSingle(title: "选择相关书籍", defaultQuery: "三体"),
            consumer: .mixedSingle(actionLabel: "相关书籍已直接回流"),
            runtimeHint: "在线结果会直接返回远端 payload，不要求先创建本地书。"
        ),
        BookSelectionTestScenario(
            id: "read-timing-relevant",
            title: "读书计时相关书籍",
            androidEntry: "ReadTimingFragment",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "单选", "远端直返", "允许创建"],
            configurationSpec: .mixedDirectSingle(title: "选择相关书籍", defaultQuery: "活着"),
            consumer: .mixedSingle(actionLabel: "读书计时相关书籍已更新"),
            runtimeHint: "用于验证与 Android 一致的“在线搜到就能直接消费”能力。"
        ),
        BookSelectionTestScenario(
            id: "edit-collection",
            title: "编辑收藏书籍集合",
            androidEntry: "EditCollectionActivity",
            group: .mixedDirectSelection,
            capabilityTags: ["本地+在线", "多选", "混合选择", "允许创建"],
            configurationSpec: .mixedDirectMultiple(title: "添加所选书籍"),
            consumer: .mixedMultiple(actionLabel: "收藏书籍集合已更新"),
            runtimeHint: "支持本地书与在线结果混合选择，确认时会统一返回混合集合。"
        ),
        BookSelectionTestScenario(
            id: "chapter-manager",
            title: "章节同步搜书",
            androidEntry: "ChapterManagerActivity",
            group: .onlineDirectSelection,
            capabilityTags: ["在线", "单选", "远端直返", "默认关键词"],
            configurationSpec: .chapterSync,
            consumer: .chapterSyncPayload,
            runtimeHint: "直接展示章节同步所需的远端 payload，不要求先创建本地书。"
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
        )
    ]

    var scenarioCount: Int {
        Self.scenarios.count
    }

    /// 读取本地书架样本，供预选和调试页概览使用；读取失败不阻断测试页打开。
    func loadSampleLocalBooks(using repository: any BookRepositoryProtocol) async {
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

    func scenarios(in group: BookSelectionScenarioGroup) -> [BookSelectionTestScenario] {
        Self.scenarios.filter { $0.group == group }
    }

    func open(_ scenario: BookSelectionTestScenario) {
        presentedScenario = scenario
    }

    func clearPresentedScenario() {
        presentedScenario = nil
    }

    /// 收口某个场景最近一次运行结果，并生成对应的消费预览面板。
    func record(_ result: BookPickerResult, for scenario: BookSelectionTestScenario) {
        previewsByScenarioID[scenario.id] = makePreview(result: result, scenario: scenario)
    }

    func preview(for scenario: BookSelectionTestScenario) -> BookSelectionScenarioPreview {
        previewsByScenarioID[scenario.id] ?? placeholderPreview(for: scenario)
    }

    var localBookSummary: String {
        if isLoadingSampleLocalBooks {
            return "正在读取本地书架样本…"
        }
        if sampleLocalBooks.isEmpty {
            return "当前未检测到本地书籍，相关场景仍可打开，但预选/回填会从空书架起步。"
        }
        return "已读取 \(sampleLocalBooks.count) 本本地书，可用于预选与本地回填验证。"
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
                message: "本次操作已取消，没有新的回流结果。",
                details: []
            )
        case .addFlowRequested:
            return BookSelectionScenarioPreview(
                title: "结果预览",
                message: "当前实现请求跳转到独立新增书籍页。",
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
                    details: ["返回空数组，业务侧据此解释为“全部 / 未限制”。"]
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
                message: "章节同步需要远端结果 payload，当前返回值不符合预期。",
                details: selection.map { [selectionLine($0)] } ?? []
            )
        }

        return BookSelectionScenarioPreview(
            title: "章节同步 Payload",
            message: "已拿到可直接用于章节同步的远端结果。",
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
                message: "补全书籍信息需要远端结果 payload，当前返回值不符合预期。",
                details: selection.map { [selectionLine($0)] } ?? []
            )
        }

        return BookSelectionScenarioPreview(
            title: "补全书籍信息 Payload",
            message: "已拿到可直接补全录入页的远端结果。",
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

    static func mixedDirectMultiple(title: String) -> Self {
        Self(
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
            preselectionStrategy: .none
        )
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
#endif
