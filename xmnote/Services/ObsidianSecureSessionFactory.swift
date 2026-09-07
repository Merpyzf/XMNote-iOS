/**
 * [INPUT]: 依赖 URLSession、Security 与 CryptoKit，接收单一 Obsidian 主机和用户确认的证书 SHA-256
 * [OUTPUT]: 对外提供仅放行系统可信 TLS 或该主机叶证书精确指纹的 URLSession
 * [POS]: Services 层 Obsidian TLS 安全边界；不关闭证书校验，也不把固定规则扩展到其他主机
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import Security

/// 为一次冻结的 Obsidian 连接创建专用会话；delegate 由 URLSession 强持有至会话失效。
nonisolated enum ObsidianSecureSessionFactory {
    static func make(host: String, pinnedCertificateSHA256: String) -> URLSession {
        let delegate = ObsidianServerTrustDelegate(
            host: host,
            pinnedCertificateSHA256: pinnedCertificateSHA256
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

/// 系统信任优先；仅系统评估失败时才允许用户确认的单主机叶证书 SHA-256。
private final class ObsidianServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String
    private let fingerprint: String

    init(host: String, pinnedCertificateSHA256: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        fingerprint = Self.normalized(pinnedCertificateSHA256)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard !fingerprint.isEmpty,
              challenge.protectionSpace.host.lowercased() == host,
              let certificate = SecTrustCopyCertificateChain(trust).flatMap({ chain in
                  CFArrayGetCount(chain) > 0
                      ? unsafeBitCast(CFArrayGetValueAtIndex(chain, 0), to: SecCertificate.self)
                      : nil
              }) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }
}
