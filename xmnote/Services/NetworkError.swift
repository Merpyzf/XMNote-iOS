/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NetworkError 枚举，统一网络与 WebDAV 错误语义
 * [POS]: Services 模块的错误类型定义，被 WebDAVClient 与 BackupService 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum NetworkError: LocalizedError {
    case unauthorized
    case notFound
    case serverError(statusCode: Int)
    case connectionFailed(underlying: Error)
    case xmlParsingFailed
    case invalidResponse
    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "认证失败，请检查账号密码"
        case .notFound:
            return "资源不存在"
        case .serverError(let code):
            return "服务器错误 (\(code))"
        case .connectionFailed:
            return "网络连接失败，请检查网络设置"
        case .xmlParsingFailed:
            return "响应解析失败"
        case .invalidResponse:
            return "响应格式异常"
        case .unknown(let error):
            return "未知错误: \(error.localizedDescription)"
        }
    }
}
