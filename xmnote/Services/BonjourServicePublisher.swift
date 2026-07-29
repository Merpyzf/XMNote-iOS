/**
 * [INPUT]: 依赖 Foundation NetService 与已经监听的 HTTP 端口
 * [OUTPUT]: 对外发布 `_http._tcp` Bonjour 服务并回传系统冲突改名或发布失败
 * [POS]: Services 的 DNS-SD 发布适配层，只公告现有 socket，不创建第二个 listener
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 将 Hummingbird 已监听的端口注册到 Bonjour，并由系统处理服务名冲突。
@MainActor
final class BonjourServicePublisher: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var onNameChange: (@MainActor @Sendable (String) -> Void)?
    private var onFailure: (@MainActor @Sendable (String) -> Void)?

    /// 发布现有 HTTP 端口；不使用 noAutoRename，让 Bonjour 冲突时选择可用服务名。
    func start(
        port: Int,
        onNameChange: @escaping @MainActor @Sendable (String) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        stop()
        self.onNameChange = onNameChange
        self.onFailure = onFailure
        let service = NetService(
            domain: "local.",
            type: "_http._tcp.",
            name: "XMNote",
            port: Int32(port)
        )
        service.delegate = self
        self.service = service
        service.publish()
    }

    /// 停止 DNS-SD 公告；底层 HTTP listener 的生命周期由会话 owner 单独管理。
    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        onNameChange = nil
        onFailure = nil
    }

    /// 接收发布完成后的最终服务名，包含系统自动冲突改名结果。
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        let publishedName = sender.name
        Task { @MainActor [weak self] in
            self?.onNameChange?(publishedName)
        }
    }

    /// 将 DNS-SD 错误转换为用户提示；回调切回 MainActor，避免代理线程直接修改会话状态。
    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue
        let message: String
        if code == -65570 {
            message = "本地网络权限被拒绝，请在“设置”中允许 XMNote 访问本地网络"
        } else {
            message = "Bonjour 服务发布失败（错误码 \(code.map(String.init) ?? "未知")），仍可在允许本地网络后重试"
        }
        Task { @MainActor [weak self] in
            self?.onFailure?(message)
        }
    }
}
