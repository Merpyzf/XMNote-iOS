#if DEBUG
import Foundation

/**
 * [INPUT]: 依赖 BookSearchWebScenarioService 提供网页场景抓取与探针结果，依赖 DoubanWebLoginService 提供豆瓣登录态判定
 * [OUTPUT]: 对外提供 WebHTMLFetchTestViewModel（网页抓取测试状态编排）
 * [POS]: Debug 网页抓取测试页状态中枢，覆盖预设搜索场景、手动 URL、Cookie 复用、豆瓣登录回流与结果预览
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class WebHTMLFetchTestViewModel {
    enum RunStatus: String {
        case idle
        case loading
        case success
        case failed

        var title: String {
            switch self {
            case .idle:
                return "未开始"
            case .loading:
                return "抓取中"
            case .success:
                return "成功"
            case .failed:
                return "失败"
            }
        }
    }

    enum SessionSelection: String, CaseIterable, Identifiable {
        case scenarioDefault
        case sharedDefault
        case sharedDouban
        case ephemeral

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scenarioDefault:
                return "按场景默认"
            case .sharedDefault:
                return WebSessionScope.sharedDefault.title
            case .sharedDouban:
                return WebSessionScope.sharedDouban.title
            case .ephemeral:
                return WebSessionScope.ephemeral.title
            }
        }

        func resolve(defaultScope: WebSessionScope) -> WebSessionScope {
            switch self {
            case .scenarioDefault:
                return defaultScope
            case .sharedDefault:
                return .sharedDefault
            case .sharedDouban:
                return .sharedDouban
            case .ephemeral:
                return .ephemeral
            }
        }
    }

    struct AttemptOutcome: Identifiable {
        let id = UUID()
        let channelTitle: String
        let summary: String
        let finalURL: String?
        let elapsedMilliseconds: Int?
        let probeStatusTitle: String?
    }

    struct DoubanBookRow: Identifiable {
        let doubanId: Int
        let title: String
        let coverURLString: String
        let info: String

        var id: Int { doubanId }
    }

    struct UserFacingRecovery {
        let title: String
        let message: String
        let primaryButtonTitle: String?
        let secondaryButtonTitle: String?
        let retryButtonTitle: String?
    }

    struct Outcome {
        var status: RunStatus = .idle
        var message: String?
        var finalURL: String?
        var pageTitle: String?
        var htmlLength: Int?
        var elapsedMilliseconds: Int?
        var cookieCount: Int?
        var htmlPreview: String?
        var probeSummary: String?
        var probeStatusTitle: String?
        var selectorHits: [String] = []
        var initialChannelTitle: String?
        var selectedChannelTitle: String?
        var fallbackReason: String?
        var attempts: [AttemptOutcome] = []
        var doubanBooks: [DoubanBookRow] = []
        var userFacingRecovery: UserFacingRecovery?
    }

    struct PresetItem: Identifiable {
        let id = UUID()
        let scenario: BookSearchWebScenario
        var outcome = Outcome()

        var title: String {
            scenario.title
        }

        var note: String {
            scenario.note
        }
    }

    struct DoubanLoginPresentation: Identifiable {
        let id = UUID()
        let presetID: UUID?
        let title: String
    }

    var selectedChannel: WebFetchChannel = .automatic
    var selectedSession: SessionSelection = .scenarioDefault
    var manualURLInput = "https://search.douban.com/book/subject_search?search_text=三体&cat=1001&start=0"

    var presets: [PresetItem]
    var manualOutcome = Outcome()
    var isRunningAll = false
    var lastBatchRunAt: Date?
    var activeDoubanLoginPresentation: DoubanLoginPresentation?

    private let scenarioService: BookSearchWebScenarioService
    private let doubanLoginService: DoubanWebLoginService

    init(
        scenarioService: BookSearchWebScenarioService,
        doubanLoginService: DoubanWebLoginService
    ) {
        self.scenarioService = scenarioService
        self.doubanLoginService = doubanLoginService
        self.presets = WebHTMLFetchTestViewModel.makeDefaultPresets()
    }

    convenience init() {
        self.init(
            scenarioService: BookSearchWebScenarioService(),
            doubanLoginService: .shared
        )
    }

    var successCount: Int {
        presets.filter { $0.outcome.status == .success }.count
    }

    var failedCount: Int {
        presets.filter { $0.outcome.status == .failed }.count
    }

    func runAll() async {
        guard !isRunningAll else { return }
        isRunningAll = true
        defer {
            isRunningAll = false
            lastBatchRunAt = Date()
        }

        let ids = presets.map(\.id)
        for id in ids {
            await runPreset(id)
        }
    }

    func runPreset(_ id: UUID) async {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let scenario = presets[index].scenario
        presets[index].outcome = Outcome(status: .loading)
        do {
            let result = try await scenarioService.execute(
                scenario,
                channel: selectedChannel,
                sessionScope: resolvedSession(for: scenario)
            )
            presets[index].outcome = makeOutcome(from: result, scenario: scenario)
        } catch {
            presets[index].outcome = makeFailureOutcome(error)
        }
    }

    func runManual() async {
        let trimmed = manualURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            manualOutcome = Outcome(status: .failed, message: "请输入 URL。")
            return
        }

        manualOutcome = Outcome(status: .loading)
        do {
            let scenario = BookSearchWebScenario.manual(urlString: trimmed)
            let result = try await scenarioService.execute(
                scenario,
                channel: selectedChannel,
                sessionScope: resolvedSession(for: scenario)
            )
            manualOutcome = makeOutcome(from: result, scenario: scenario)
        } catch {
            manualOutcome = makeFailureOutcome(error)
        }
    }

    func resetAll() {
        presets = presets.map { item in
            var updated = item
            updated.outcome = Outcome()
            return updated
        }
        manualOutcome = Outcome()
        activeDoubanLoginPresentation = nil
        lastBatchRunAt = nil
    }

    func presentDoubanLogin(for presetID: UUID) async {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let scenario = presets[index].scenario
        guard isDoubanScenario(scenario) else { return }

        if await doubanLoginService.isLoggedIn() {
            applyRecovery(.loggedIn, for: presetID)
            return
        }

        activeDoubanLoginPresentation = DoubanLoginPresentation(
            presetID: presetID,
            title: loginTitle(for: scenario)
        )
    }

    func presentDoubanLoginEntry() async {
        if await doubanLoginService.isLoggedIn() {
            return
        }

        activeDoubanLoginPresentation = DoubanLoginPresentation(
            presetID: nil,
            title: "登录完成后可直接返回这里继续测试"
        )
    }

    func handleDoubanLoginDismissed() async {
        guard let presentation = activeDoubanLoginPresentation else { return }
        activeDoubanLoginPresentation = nil

        guard let presetID = presentation.presetID else {
            return
        }

        if await doubanLoginService.isLoggedIn() {
            applyRecovery(.loggedIn, for: presetID)
        } else {
            applyRecovery(.dismissed, for: presetID)
        }
    }

    func handleDoubanLoginSucceeded() {
        guard let presentation = activeDoubanLoginPresentation else { return }
        activeDoubanLoginPresentation = nil
        guard let presetID = presentation.presetID else { return }
        applyRecovery(.loggedIn, for: presetID)
    }
}

private extension WebHTMLFetchTestViewModel {
    enum RecoveryDisplayState {
        case needsLogin
        case loggedIn
        case dismissed
    }

    static func makeDefaultPresets() -> [PresetItem] {
        [
            PresetItem(scenario: .doubanSearch(keyword: "三体", page: 1)),
            PresetItem(scenario: .doubanDetail(doubanId: "30266730")),
            PresetItem(scenario: .doubanISBN(isbn: "9787536692930")),
            PresetItem(scenario: .doubanAuthor(urlString: "https://book.douban.com/author/4519116/")),
            PresetItem(scenario: .qidianSearch(keyword: "诡秘之主", page: 1))
        ]
    }

    func resolvedSession(for scenario: BookSearchWebScenario) -> WebSessionScope {
        let defaultScope: WebSessionScope
        switch scenario {
        case .doubanSearch, .doubanDetail, .doubanISBN, .doubanAuthor:
            defaultScope = .sharedDouban
        case .qidianSearch, .manual:
            defaultScope = .sharedDefault
        }
        return selectedSession.resolve(defaultScope: defaultScope)
    }

    func makeOutcome(from result: ScenarioFetchResult, scenario: BookSearchWebScenario) -> Outcome {
        let doubanBooks: [DoubanBookRow]
        switch result.parsedPayload {
        case .doubanBooks(let items):
            doubanBooks = items.map {
                DoubanBookRow(
                    doubanId: $0.doubanId,
                    title: $0.title,
                    coverURLString: $0.coverURLString,
                    info: $0.info
                )
            }
        case nil:
            doubanBooks = []
        }

        return Outcome(
            status: .success,
            message: nil,
            finalURL: result.fetchResult.finalURL.absoluteString,
            pageTitle: result.fetchResult.pageTitle ?? result.probe.title,
            htmlLength: result.fetchResult.htmlLength,
            elapsedMilliseconds: result.fetchResult.elapsedMilliseconds,
            cookieCount: result.fetchResult.cookies.count,
            htmlPreview: String(result.fetchResult.html.prefix(1_600)),
            probeSummary: result.probe.summary,
            probeStatusTitle: result.probe.status.title,
            selectorHits: result.probe.selectorHits,
            initialChannelTitle: result.attemptedChannels.first?.title,
            selectedChannelTitle: result.selectedChannel.title,
            fallbackReason: result.fallbackReason,
            attempts: result.attempts.map {
                AttemptOutcome(
                    channelTitle: $0.channel.title,
                    summary: $0.summary,
                    finalURL: $0.finalURL?.absoluteString,
                    elapsedMilliseconds: $0.elapsedMilliseconds,
                    probeStatusTitle: $0.probeStatusTitle
                )
            },
            doubanBooks: doubanBooks,
            userFacingRecovery: makeRecoveryIfNeeded(
                scenario: scenario,
                probeStatus: result.probe.status
            )
        )
    }

    func makeFailureOutcome(_ error: Error) -> Outcome {
        Outcome(
            status: .failed,
            message: error.localizedDescription,
            finalURL: nil,
            pageTitle: nil,
            htmlLength: nil,
            elapsedMilliseconds: nil,
            cookieCount: nil,
            htmlPreview: nil,
            probeSummary: nil,
            probeStatusTitle: nil,
            selectorHits: [],
            initialChannelTitle: nil,
            selectedChannelTitle: nil,
            fallbackReason: nil,
            attempts: [],
            doubanBooks: [],
            userFacingRecovery: nil
        )
    }

    func makeRecoveryIfNeeded(
        scenario: BookSearchWebScenario,
        probeStatus: ScenarioProbeResult.Status
    ) -> UserFacingRecovery? {
        guard isDoubanScenario(scenario), probeStatus == .antiBot else {
            return nil
        }
        return makeRecovery(for: scenario, state: .needsLogin)
    }

    func applyRecovery(_ state: RecoveryDisplayState, for presetID: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let scenario = presets[index].scenario
        presets[index].outcome.userFacingRecovery = makeRecovery(for: scenario, state: state)
    }

    func makeRecovery(
        for scenario: BookSearchWebScenario,
        state: RecoveryDisplayState
    ) -> UserFacingRecovery {
        switch state {
        case .needsLogin:
            if isSearchScenario(scenario) {
                return UserFacingRecovery(
                    title: "先登录豆瓣，再继续搜索",
                    message: "为了继续获取书籍信息，请先完成一次豆瓣登录。登录完成后，回到这里即可继续搜索。",
                    primaryButtonTitle: "去登录豆瓣",
                    secondaryButtonTitle: "稍后再说",
                    retryButtonTitle: nil
                )
            }
            return UserFacingRecovery(
                title: "先登录豆瓣，再继续获取内容",
                message: "当前需要先完成豆瓣登录，才能继续获取这本书的详细信息。登录完成后，回到这里重试即可。",
                primaryButtonTitle: "去登录豆瓣",
                secondaryButtonTitle: "稍后再说",
                retryButtonTitle: nil
            )
        case .loggedIn:
            if isSearchScenario(scenario) {
                return UserFacingRecovery(
                    title: "已完成豆瓣登录，可以继续搜索了",
                    message: "请重新尝试刚才的搜索。",
                    primaryButtonTitle: nil,
                    secondaryButtonTitle: nil,
                    retryButtonTitle: "重新搜索"
                )
            }
            return UserFacingRecovery(
                title: "已完成豆瓣登录，可以继续获取内容了",
                message: "请重新尝试刚才的操作。",
                primaryButtonTitle: nil,
                secondaryButtonTitle: nil,
                retryButtonTitle: "重新获取"
            )
        case .dismissed:
            return UserFacingRecovery(
                title: "还没有完成豆瓣登录",
                message: "你可以稍后再登录，完成后再回来继续当前操作。",
                primaryButtonTitle: "继续登录",
                secondaryButtonTitle: nil,
                retryButtonTitle: nil
            )
        }
    }

    func isDoubanScenario(_ scenario: BookSearchWebScenario) -> Bool {
        switch scenario {
        case .doubanSearch, .doubanDetail, .doubanISBN, .doubanAuthor:
            return true
        case .qidianSearch, .manual:
            return false
        }
    }

    func isSearchScenario(_ scenario: BookSearchWebScenario) -> Bool {
        switch scenario {
        case .doubanSearch:
            return true
        case .doubanDetail, .doubanISBN, .doubanAuthor, .qidianSearch, .manual:
            return false
        }
    }

    func loginTitle(for scenario: BookSearchWebScenario) -> String {
        isSearchScenario(scenario) ? "登录豆瓣后继续搜索" : "登录豆瓣后继续获取内容"
    }
}
#endif
