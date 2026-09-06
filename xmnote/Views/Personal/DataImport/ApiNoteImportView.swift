/**
 * [INPUT]: 依赖 ApiNoteImportViewModel、统一预览、受会员保护的 Repository 注入与 App 生命周期
 * [OUTPUT]: 对外提供 8080 API 导入页面，基于系统有效接口展示地址/访问码并接收多次 `/send`
 * [POS]: Views/Personal/DataImport 的 API 特殊入口；离开页面或 App 进入后台即停止服务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct ApiNoteImportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ApiNoteImportViewModel
    let repository: any NoteImportRepositoryProtocol
    let onOpenPremium: () -> Void

    init(repository: any NoteImportRepositoryProtocol, membership: any MembershipRepositoryProtocol, onOpenPremium: @escaping () -> Void) {
        self.repository = repository
        self.onOpenPremium = onOpenPremium
        _model = State(initialValue: ApiNoteImportViewModel(membership: membership))
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
