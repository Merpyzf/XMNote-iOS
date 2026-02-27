/**
 * [INPUT]: 依赖 Alamofire Session 提供 HTTP 请求能力
 * [OUTPUT]: 对外提供 NetworkClient，封装 Basic Auth 与无认证两种 Session
 * [POS]: Services 模块的网络基础设施，被 WebDAVClient 依赖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Alamofire

final class NetworkClient: Sendable {
    let session: Session

    /// 带 Basic Auth 的客户端（WebDAV 场景）
    init(username: String, password: String,
         requestTimeout: TimeInterval = 30,
         resourceTimeout: TimeInterval = 300) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout

        let interceptor = BasicAuthInterceptor(username: username, password: password)

        #if DEBUG
        session = Session(
            configuration: config,
            interceptor: interceptor,
            eventMonitors: [NetworkLogger()]
        )
        #else
        session = Session(
            configuration: config,
            interceptor: interceptor
        )
        #endif
    }

    /// 无认证客户端（公开 API 场景，后续扩展用）
    init(requestTimeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout

        #if DEBUG
        session = Session(
            configuration: config,
            eventMonitors: [NetworkLogger()]
        )
        #else
        session = Session(configuration: config)
        #endif
    }
}

// MARK: - Basic Auth Interceptor

private struct BasicAuthInterceptor: RequestInterceptor, Sendable {
    let credential: String

    init(username: String, password: String) {
        let data = Data("\(username):\(password)".utf8)
        credential = "Basic \(data.base64EncodedString())"
    }

    func adapt(_ urlRequest: URLRequest,
               for session: Session,
               completion: @escaping (Result<URLRequest, Error>) -> Void) {
        var request = urlRequest
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        completion(.success(request))
    }

    func retry(_ request: Request,
               for session: Session,
               dueTo error: Error,
               completion: @escaping (RetryResult) -> Void) {
        // 401 不重试
        if let response = request.task?.response as? HTTPURLResponse,
           response.statusCode == 401 {
            completion(.doNotRetry)
            return
        }
        // 网络瞬断最多重试 2 次
        if request.retryCount < 2,
           let urlError = error.asAFError?.underlyingError as? URLError,
           [.notConnectedToInternet, .timedOut, .networkConnectionLost].contains(urlError.code) {
            completion(.retryWithDelay(1.0))
            return
        }
        completion(.doNotRetry)
    }
}

// MARK: - Network Logger

#if DEBUG
private final class NetworkLogger: EventMonitor, @unchecked Sendable {
    func requestDidResume(_ request: Request) {
        let method = request.request?.httpMethod ?? "?"
        let url = request.request?.url?.absoluteString ?? "?"
        print("[Network] \(method) \(url)")
    }

    func request(_ request: DataRequest, didParseResponse response: DataResponse<Data?, AFError>) {
        let code = response.response?.statusCode ?? 0
        let method = request.request?.httpMethod ?? "?"
        let url = request.request?.url?.absoluteString ?? "?"
        print("[Network] \(method) \(url) → \(code)")

        if let data = response.data, let body = String(data: data, encoding: .utf8) {
            let preview = body.prefix(2000)
            print("[Network] Body: \(preview)")
        }

        if let error = response.error {
            print("[Network] Error: \(error)")
        }
    }
}
#endif
