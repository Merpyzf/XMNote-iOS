/**
 * [INPUT]: 依赖 ApiNoteImportServer、LocalNetworkEndpointProvider、API 会话合并策略与会员状态
 * [OUTPUT]: 对外提供 ApiNoteImportViewModel，管理 8080 API 导入会话、局域网地址、载荷合并与预览状态
 * [POS]: ViewModels/Personal 的 API 导入状态 owner；页面只负责投影状态并转发用户动作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 管理 API 导入页面会话，并在页面离开或 App 进入后台时由调用方显式停止资源。
@MainActor @Observable
final class ApiNoteImportViewModel {
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
        if let saved = defaults.string(forKey: "apiImportAccessCode"), !saved.isEmpty {
            accessCode = saved
        } else {
            let generated = String(format: "%06d", Int.random(in: 0...999_999))
            defaults.set(generated, forKey: "apiImportAccessCode")
            accessCode = generated
        }
    }

    /// 启动 8080 导入服务与共享局域网地址发现；异步回调回到 MainActor，服务由 stop() 终止。
    func start() {
        guard isPremium else {
            errorMessage = "API 导入是会员功能"
            return
        }
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
        if case .failed(let message) = value {
            errorMessage = message
        }
    }

    /// 停止 listener 与地址监听；服务器 actor 串行处理停止请求，随后不再接收新载荷。
    func stop() {
        endpointProvider?.stop()
        endpointProvider = nil
        Task { await server.stop() }
        state = .stopped
    }

    /// 仅在已收到至少一本书时进入统一预览。
    func openPreview() {
        guard !books.isEmpty else {
            errorMessage = "尚未收到可导入的书籍"
            return
        }
        opensPreview = true
    }
}
