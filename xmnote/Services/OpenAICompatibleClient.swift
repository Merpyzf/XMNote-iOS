/**
 * [INPUT]: 依赖 Foundation URLSession，接收供应商地址、模型、短生命周期 API Key、消息与生成参数
 * [OUTPUT]: 对外提供 OpenAICompatibleClient 的 SSE 累积文本流与非流式完整文本请求
 * [POS]: Services 层 OpenAI-compatible 网络适配器，被 AIRepository 使用，不持久化凭据或访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// OpenAI-compatible 消息角色与文本。
nonisolated struct OpenAIChatMessage: Encodable, Equatable, Sendable {
    let role: String
    let content: String
}

/// Repository 组装后的 OpenAI-compatible 请求；API Key 只在单次调用生命周期内持有。
nonisolated struct OpenAICompletionRequest: Sendable {
    enum ResponseFormat: String, Sendable {
        case text
        case jsonObject = "json_object"
    }

    let baseURLString: String
    let apiKey: String
    let modelID: String
    let messages: [OpenAIChatMessage]
    let responseFormat: ResponseFormat
    let isStreaming: Bool
    let frequencyPenalty: Double
    let presencePenalty: Double
    let temperature: Double
    let topP: Double
}

/// OpenAI-compatible 客户端；流式任务终止会取消底层 URLSession 读取，非流式调用遵循结构化取消。
nonisolated final class OpenAICompatibleClient: @unchecked Sendable {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 注入 URLSession；默认使用无磁盘缓存的临时会话，避免包含认证头的请求落入持久缓存。
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 发起 SSE 流式请求并持续产出“截至当前的完整累积文本”；取消消费流会取消网络任务。
    func streamCompletion(_ request: OpenAICompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(from: request, streaming: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try validate(response)

                    var accumulated = ""
                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = Self.ssePayload(from: rawLine) else { continue }
                        if payload == "[DONE]" { break }

                        let data = Data(payload.utf8)
                        let chunk = try decoder.decode(ChatCompletionChunk.self, from: data)
                        guard let delta = chunk.choices.first?.delta.content, !delta.isEmpty else {
                            continue
                        }
                        accumulated.append(delta)
                        continuation.yield(accumulated)
                    }

                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AIRepositoryError.emptyResponse
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: map(error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// 发起非流式请求并返回完整消息文本；自动标签使用此路径以保证 JSON 一次性解析。
    func completion(_ request: OpenAICompletionRequest) async throws -> String {
        do {
            let urlRequest = try makeURLRequest(from: request, streaming: false)
            let (data, response) = try await session.data(for: urlRequest)
            try Task.checkCancellation()
            try validate(response)
            let result = try decoder.decode(ChatCompletionResponse.self, from: data)
            guard let content = result.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIRepositoryError.emptyResponse
            }
            return content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw map(error)
        }
    }

    private func makeURLRequest(
        from request: OpenAICompletionRequest,
        streaming: Bool
    ) throws -> URLRequest {
        guard var baseURL = URL(string: request.baseURLString),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https",
              baseURL.host != nil else {
            throw AIRepositoryError.invalidConfiguration("AI 服务地址无效。")
        }
        baseURL.append(path: "v1/chat/completions")

        let payload = ChatCompletionPayload(
            model: request.modelID,
            messages: request.messages,
            stream: streaming,
            frequencyPenalty: request.frequencyPenalty,
            presencePenalty: request.presencePenalty,
            responseFormat: .init(type: request.responseFormat.rawValue),
            temperature: request.temperature,
            topP: request.topP
        )
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(payload)
        return urlRequest
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AIRepositoryError.network("服务没有返回有效 HTTP 响应")
        }
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw AIRepositoryError.unauthorized
        case 403:
            throw AIRepositoryError.forbidden
        case 429:
            throw AIRepositoryError.rateLimited
        default:
            throw AIRepositoryError.service(statusCode: response.statusCode)
        }
    }

    private func map(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let repositoryError = error as? AIRepositoryError {
            return repositoryError
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return CancellationError()
            }
            switch urlError.code {
            case .notConnectedToInternet:
                return AIRepositoryError.network("当前设备未连接网络")
            case .timedOut:
                return AIRepositoryError.network("请求超时")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return AIRepositoryError.network("无法连接 AI 服务")
            default:
                return AIRepositoryError.network(urlError.localizedDescription)
            }
        }
        if error is DecodingError {
            return AIRepositoryError.network("AI 服务返回了无法识别的数据")
        }
        return AIRepositoryError.network(error.localizedDescription)
    }

    private nonisolated static func ssePayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }
}

nonisolated private struct ChatCompletionPayload: Encodable {
    nonisolated struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [OpenAIChatMessage]
    let stream: Bool
    let frequencyPenalty: Double
    let presencePenalty: Double
    let responseFormat: ResponseFormat
    let temperature: Double
    let topP: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
        case topP = "top_p"
    }
}

nonisolated private struct ChatCompletionChunk: Decodable {
    nonisolated struct Choice: Decodable {
        nonisolated struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

nonisolated private struct ChatCompletionResponse: Decodable {
    nonisolated struct Choice: Decodable {
        nonisolated struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
