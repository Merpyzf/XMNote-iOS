/**
 * [INPUT]: 依赖 ApiNoteImportServer、LocalNetworkEndpointProvider、API 会话合并策略与 MembershipRepository 实时权益
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
    private let membership: any MembershipRepositoryProtocol
    @ObservationIgnored private var membershipTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    private var generation = 0
    private var endpointProvider: LocalNetworkEndpointProvider?

    init(membership: any MembershipRepositoryProtocol) {
        self.membership = membership
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
        generation += 1
        let token = generation
        startTask?.cancel()
        startTask = Task {
            do { try await membership.requirePremium() }
            catch {
                guard token == generation else { return }
                errorMessage = error.localizedDescription
                stop()
                return
            }
            guard token == generation, !Task.isCancelled else { return }
            endpointProvider?.stop()
            let provider = LocalNetworkEndpointProvider()
            endpointProvider = provider
            provider.start(port: 8080, path: "/send") { [weak self] endpoints in
                guard let self, token == self.generation else { return }
                self.address = endpoints.first?.url.absoluteString ?? "等待局域网地址"
            }
            errorMessage = nil
            let membership = membership
            await server.start(accessCode: accessCode, hasPremiumAccess: { await membership.hasPremiumAccess() }) { [weak self] incoming in
                await self?.receive(incoming, generation: token)
            } onState: { [weak self] state in
                await self?.receive(state, generation: token)
            }
        }
        if membershipTask == nil {
            membershipTask = Task { [weak self, membership] in
                let stream = await membership.states()
                for await snapshot in stream {
                    guard let self, !Task.isCancelled else { return }
                    if !snapshot.isPremium && snapshot.operation == nil {
                        self.stop()
                        self.errorMessage = snapshot.isLoaded
                            ? "会员权益不可用，已停止接收；已收到的书籍仍保留"
                            : MembershipError.notReady.localizedDescription
                    }
                }
            }
        }
    }

    private func receive(_ incoming: ApiImportBookPayload, generation token: Int) {
        guard token == generation else { return }
        ApiImportBookMergePolicy.addOrMergeBook(&books, incoming: incoming)
        ApiImportBookMergePolicy.sortForImport(&books)
    }

    private func receive(_ value: ApiNoteImportServer.State, generation token: Int) {
        guard token == generation else { return }
        state = value
        if case .failed(let message) = value {
            errorMessage = message
        }
    }

    /// 停止 listener 与地址监听；服务器 actor 串行处理停止请求，随后不再接收新载荷。
    func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        membershipTask?.cancel()
        membershipTask = nil
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
