/**
 * [INPUT]: 依赖 ApiNoteImportServer、API 会话合并策略、统一预览与 App 生命周期
 * [OUTPUT]: 对外提供 8080 API 导入页面，展示地址/访问码并接收多次 `/send`
 * [POS]: Views/Personal/DataImport 的 API 特殊入口；离开页面或 App 进入后台即停止服务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Darwin
import Observation
import SwiftUI

@MainActor @Observable
private final class ApiNoteImportViewModel {
    var state: ApiNoteImportServer.State = .stopped
    var books: [ApiImportBookPayload] = []
    var errorMessage: String?
    var opensPreview = false
    let accessCode: String
    let address: String
    private let server = ApiNoteImportServer()
    private let isPremium: Bool

    init(isPremium: Bool) {
        self.isPremium = isPremium
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "apiImportAccessCode"), !saved.isEmpty { accessCode = saved }
        else { let generated = String(format: "%06d", Int.random(in: 0...999_999)); defaults.set(generated, forKey: "apiImportAccessCode"); accessCode = generated }
        address = "http://\(Self.localIPv4Address() ?? "设备局域网 IP"):8080/send"
    }

    func start() {
        guard isPremium else { errorMessage = "API 导入是会员功能"; return }
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

    func stop() { Task { await server.stop() }; state = .stopped }
    func openPreview() { guard !books.isEmpty else { errorMessage = "尚未收到可导入的书籍"; return }; opensPreview = true }

    private nonisolated static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 { return String(cString: host) }
        }
        return nil
    }
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
        .alert("API 导入", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("取消", role: .cancel) { model.errorMessage = nil }
            Button("升级会员") { onOpenPremium() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var stateIsActive: Bool { stateText == "启动中" || stateText == "运行中" }
    private var stateText: String {
        switch model.state { case .stopped: "已停止"; case .starting: "启动中"; case .running: "运行中"; case .failed: "启动失败" }
    }
}
