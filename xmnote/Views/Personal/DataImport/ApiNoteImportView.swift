/**
 * [INPUT]: 依赖 ApiNoteImportServer、LocalNetworkEndpointProvider、API 会话合并策略、统一预览与 App 生命周期
 * [OUTPUT]: 对外提供 8080 API 导入页面，基于系统有效接口展示地址/访问码并接收多次 `/send`
 * [POS]: Views/Personal/DataImport 的 API 特殊入口；离开页面或 App 进入后台即停止服务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Observation
import SwiftUI

@MainActor @Observable
private final class ApiNoteImportViewModel {
    var state: ApiNoteImportServer.State = .stopped
    var books: [ApiImportBookPayload] = []
    var errorMessage: String?
    var opensPreview = false
    let accessCode: String
    var address = "等待局域网地址"
    private let server = ApiNoteImportServer()
    private let isPremium: Bool
    private var endpointProvider: LocalNetworkEndpointProvider?

    init(isPremium: Bool) {
        self.isPremium = isPremium
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "apiImportAccessCode"), !saved.isEmpty { accessCode = saved }
        else { let generated = String(format: "%06d", Int.random(in: 0...999_999)); defaults.set(generated, forKey: "apiImportAccessCode"); accessCode = generated }
    }

    /// 启动 8080 导入服务与共享局域网地址发现；两者均随页面会话停止。
    func start() {
        guard isPremium else { errorMessage = "API 导入是会员功能"; return }
        endpointProvider?.stop()
        let provider = LocalNetworkEndpointProvider()
        endpointProvider = provider
        provider.start(port: 8080, path: "/send") { [weak self] endpoints in
            self?.address = endpoints.first?.url.absoluteString ?? "等待局域网地址"
        }
        Task {
            await server.start(accessCode: accessCode, isPremium: isPremium) { [weak self] incoming in
                await self?.receive(incoming)
            } onState: { [weak self] state in
                await self?.receive(state)
            }
        }
    }

    private func receive(_ incoming: ApiImportBookPayload) {
        ApiImportBookMergePolicy.addOrMergeBook(&books, incoming: incoming)
        ApiImportBookMergePolicy.sortForImport(&books)
    }

    private func receive(_ value: ApiNoteImportServer.State) {
        state = value
        if case .failed(let message) = value { errorMessage = message }
    }

    /// 停止导入 listener 与地址监听；服务器任务取消后不再接收新请求。
    func stop() {
        endpointProvider?.stop()
        endpointProvider = nil
        Task { await server.stop() }
        state = .stopped
    }

    /// 仅在已收到至少一本书时进入统一预览。
    func openPreview() { guard !books.isEmpty else { errorMessage = "尚未收到可导入的书籍"; return }; opensPreview = true }
}

struct ApiNoteImportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ApiNoteImportViewModel
    let repository: any NoteImportRepositoryProtocol
    let onOpenPremium: () -> Void

    init(repository: any NoteImportRepositoryProtocol, isPremium: Bool, onOpenPremium: @escaping () -> Void) {
        self.repository = repository
        self.onOpenPremium = onOpenPremium
        _model = State(initialValue: ApiNoteImportViewModel(isPremium: isPremium))
    }

    var body: some View {
        List {
            Section("服务状态") {
                LabeledContent("状态", value: stateText)
                LabeledContent("接口地址", value: model.address)
                LabeledContent("访问码", value: model.accessCode)
                LabeledContent("已接收", value: "\(model.books.count) 本")
            }
            Section {
                Button(stateIsActive ? "停止服务" : "启动服务") { stateIsActive ? model.stop() : model.start() }
                Button("预览并导入") { model.openPreview() }.disabled(model.books.isEmpty)
            }
            Section("请求要求") {
                Text("向上方地址 POST Android API 导入 JSON，并在 X-XMNote-Access-Code 请求头中填写访问码。接口业务结果始终使用 HTTP 200 返回。")
                    .font(AppTypography.caption).foregroundStyle(Color.textSecondary)
            }
        }
        .navigationTitle("API 导入")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .navigationDestination(isPresented: $model.opensPreview) {
            UnifiedNoteImportPreviewView(books: model.books.map { $0.asNoteImportDraft() }, repository: repository)
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            descriptor: apiImportErrorDescriptor
        )
    }

    private var stateIsActive: Bool { stateText == "启动中" || stateText == "运行中" }
    private var stateText: String {
        switch model.state { case .stopped: "已停止"; case .starting: "启动中"; case .running: "运行中"; case .failed: "启动失败" }
    }

    private var apiImportErrorDescriptor: XMSystemAlertDescriptor? {
        guard let errorMessage = model.errorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "API 导入",
            message: errorMessage,
            actions: [
                XMSystemAlertAction(title: "升级会员") {
                    onOpenPremium()
                },
                XMSystemAlertAction(title: "取消", role: .cancel) {
                    model.errorMessage = nil
                }
            ]
        )
    }
}
