/**
 * [INPUT]: 依赖 Bundle 中默认空的 OneNoteClientID/OneNoteRedirectURI、MSAL 2.14.1（可用时）与当前前台 UIViewController
 * [OUTPUT]: 对外提供 OneNoteAccessTokenProviding，以 public client 交互/静默流程获取 Microsoft Graph access token
 * [POS]: Services 层 OneNote OAuth 边界；客户端不接收或保存 client secret，Graph 导出 Service 不直接操作认证 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

#if canImport(MSAL)
import MSAL
#endif

/// OneNote 导出只依赖短期 Graph access token，不感知 MSAL account cache 的实现。
protocol OneNoteAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
}

/// OneNote 认证配置缺失或运行时不可用时的安全失败。
enum OneNoteAuthenticationError: LocalizedError {
    case missingConfiguration
    case unavailable
    case noPresentationContext
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "OneNote 尚未配置 Microsoft 客户端 ID 与回调地址"
        case .unavailable: "当前构建未包含 Microsoft 登录能力"
        case .noPresentationContext: "暂时无法显示 Microsoft 登录页面"
        case .emptyToken: "Microsoft 登录未返回访问令牌"
        }
    }
}

/// 使用 MSAL public client flow 获取 Graph token；主线程只负责寻找呈现控制器和启动认证，网络等待可取消但已显示的系统认证由 MSAL 收口。
final class OneNoteAuthenticationService: OneNoteAccessTokenProviding, @unchecked Sendable {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// 优先使用 MSAL account cache 静默获取 token，缺少账户或需要交互时再展示系统认证页面。
    func accessToken() async throws -> String {
        #if canImport(MSAL)
        let clientID = (bundle.object(forInfoDictionaryKey: "OneNoteClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let redirectURI = (bundle.object(forInfoDictionaryKey: "OneNoteRedirectURI") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty, !redirectURI.isEmpty else {
            throw OneNoteAuthenticationError.missingConfiguration
        }
        return try await MainActor.run {
            try Self.makeApplication(clientID: clientID, redirectURI: redirectURI)
        }.acquireExportToken()
        #else
        throw OneNoteAuthenticationError.unavailable
        #endif
    }
}

#if canImport(MSAL)
@MainActor
private extension OneNoteAuthenticationService {
    /// 创建不含 client secret 的 Microsoft public client application。
    static func makeApplication(clientID: String, redirectURI: String) throws -> MSALPublicClientApplication {
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: nil
        )
        return try MSALPublicClientApplication(configuration: config)
    }
}

private extension MSALPublicClientApplication {
    /// MSAL 回调由 continuation 单次恢复；任务取消不会盲目重复认证或生成第二次授权请求。
    func acquireExportToken() async throws -> String {
        let scopes = ["Notes.ReadWrite", "offline_access"]
        if let account = try? allAccounts().first {
            let parameters = MSALSilentTokenParameters(scopes: scopes, account: account)
            if let token = try? await acquireSilentToken(parameters), !token.isEmpty {
                return token
            }
        }
        guard let presenter = await MainActor.run(body: UIViewController.exportTopViewController) else {
            throw OneNoteAuthenticationError.noPresentationContext
        }
        let webParameters = await MainActor.run {
            MSALWebviewParameters(authPresentationViewController: presenter)
        }
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParameters)
        return try await withCheckedThrowingContinuation { continuation in
            acquireToken(with: parameters) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = result?.accessToken, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: OneNoteAuthenticationError.emptyToken)
                }
            }
        }
    }

    /// 把 MSAL completion API 桥接为单次 async 结果，调用者取消后不自动重试可能已完成的认证。
    func acquireSilentToken(_ parameters: MSALSilentTokenParameters) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            acquireTokenSilent(with: parameters) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = result?.accessToken, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: OneNoteAuthenticationError.emptyToken)
                }
            }
        }
    }
}
#endif

@MainActor
private extension UIViewController {
    /// 从当前活动 window 找到系统认证可安全呈现的顶层控制器。
    static func exportTopViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var current = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        if let navigation = current as? UINavigationController {
            return navigation.visibleViewController ?? navigation
        }
        if let tab = current as? UITabBarController {
            return tab.selectedViewController ?? tab
        }
        return current
    }
}
