/**
 * [INPUT]: 依赖 UserDefaults 保存 Android AI 配置键，依赖 URLSession 透明转发 DeepSeek/SiliconFlow 请求
 * [OUTPUT]: 对外提供 DesktopWebAIPort，实现配置读写、非流式响应和逐块 SSE 代理
 * [POS]: Infra 层 Web AI 适配服务；凭据与网络实现不进入 XMNoteWeb Package
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb

/// 串行保护 AI 设置快照；网络请求继承调用任务取消，SSE 终止时取消上游读取任务。
actor DesktopWebAIService: DesktopWebAIPort {
    private enum Key {
        static let enabled = "LLMIsEnable"
        static let provider = "LLMClient"
        static let deepSeekAPIKey = "deepSeekAPIKey"
        static let deepSeekModel = "deepSeekLLMModel"
        static let siliconFlowAPIKey = "siliconFlowAPIKey"
        static let siliconFlowModel = "siliconFlowLLMModel"
        static let noteSystem = "noteExplanationSystemPrompt"
        static let noteUser = "noteExplanationUserPrompt"
        static let autoTagSystem = "aiTagSystemPrompt"
        static let autoTagUser = "aiTagUserPrompt"
        static let wordSystem = "wordLookupSystemPrompt"
        static let wordUser = "wordLookupUserPrompt"
    }

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    /// 返回 Android AIController 的完整配置形状；当前按基线保留明文 API Key。
    func aiConfig() async throws -> DesktopWebJSONValue {
        // NOTE(ANDROID-WEB-001): Android 直接向局域网客户端返回明文 API Key；收敛后统一评估凭据脱敏。
        .object([
            "isEnabled": .boolean((defaults.string(forKey: Key.enabled) ?? "OFF") == "ON"),
            "provider": .integer(Int64(defaults.object(forKey: Key.provider) as? Int ?? 0)),
            "deepSeek": .object([
                "apiKey": .string(defaults.string(forKey: Key.deepSeekAPIKey) ?? ""),
                "model": .string(defaults.string(forKey: Key.deepSeekModel) ?? "deepseek-chat")
            ]),
            "siliconFlow": .object([
                "apiKey": .string(defaults.string(forKey: Key.siliconFlowAPIKey) ?? ""),
                "model": .string(defaults.string(forKey: Key.siliconFlowModel) ?? "deepseek-ai/DeepSeek-V3")
            ]),
            "models": .object([
                "deepSeek": .array([.string("deepseek-chat")]),
                "siliconFlow": .array([
                    .string("deepseek-ai/DeepSeek-V3"),
                    .string("meta-llama/Llama-3.3-70B-Instruct"),
                    .string("Qwen/QwQ-32B-Preview")
                ])
            ]),
            "prompts": .object([
                "noteExplanation": promptPair(system: Key.noteSystem, user: Key.noteUser, defaults: Self.noteDefaults),
                "autoTag": promptPair(system: Key.autoTagSystem, user: Key.autoTagUser, defaults: Self.autoTagDefaults),
                "wordLookup": promptPair(system: Key.wordSystem, user: Key.wordUser, defaults: Self.wordDefaults)
            ])
        ])
    }

    /// 按 Kotlin 可空 DTO 语义仅覆盖请求出现的字段，不验证 provider、model 或 Prompt 内容。
    func updateAIConfig(_ patch: DesktopWebJSONValue) async throws {
        guard let object = patch.objectValue else {
            throw DesktopWebAPIError(code: 400, message: "Expected object")
        }
        if let enabled = object["isEnabled"]?.booleanValue {
            defaults.set(enabled ? "ON" : "OFF", forKey: Key.enabled)
        }
        if let provider = object["provider"]?.integerValue {
            defaults.set(Int(provider), forKey: Key.provider)
        }
        applyProvider(object["deepSeek"], apiKey: Key.deepSeekAPIKey, model: Key.deepSeekModel)
        applyProvider(object["siliconFlow"], apiKey: Key.siliconFlowAPIKey, model: Key.siliconFlowModel)
        if let prompts = object["prompts"]?.objectValue {
            applyPrompt(prompts["noteExplanation"], system: Key.noteSystem, user: Key.noteUser)
            applyPrompt(prompts["autoTag"], system: Key.autoTagSystem, user: Key.autoTagUser)
            applyPrompt(prompts["wordLookup"], system: Key.wordSystem, user: Key.wordUser)
        }
    }

    /// 建立上游连接后返回真实状态与原始字节；流式请求不等待完整 SSE 才响应。
    func chatCompletions(body: Data) async throws -> DesktopWebRawHTTPResponse {
        guard (defaults.string(forKey: Key.enabled) ?? "OFF") == "ON" else {
            return Self.openAIError(status: 403, message: "AI 功能已关闭")
        }
        let provider = defaults.object(forKey: Key.provider) as? Int ?? 0
        let baseURL: String
        let apiKey: String
        switch provider {
        case 0:
            baseURL = "https://api.deepseek.com"
            apiKey = defaults.string(forKey: Key.deepSeekAPIKey) ?? ""
        case 1:
            baseURL = "https://api.siliconflow.cn"
            apiKey = defaults.string(forKey: Key.siliconFlowAPIKey) ?? ""
        default:
            return Self.openAIError(status: 400, message: "未知的 AI 服务商")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.openAIError(status: 400, message: "API Key 未配置")
        }
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            return Self.openAIError(status: 502, message: "代理请求失败", type: "proxy_error")
        }
        let isStream = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["stream"] as? Bool == true
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if isStream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }

        do {
            if isStream {
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 502
                guard (200...299).contains(status) else {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    return data.isEmpty
                        ? Self.openAIError(status: status, message: "Upstream error (\(status))", type: "upstream_error")
                        : .init(
                            statusCode: status,
                            headers: ["Content-Type": "application/json"],
                            body: data
                        )
                }
                let stream = AsyncThrowingStream<Data, any Error> { continuation in
                    let task = Task {
                        do {
                            var chunk = Data()
                            chunk.reserveCapacity(4_096)
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                chunk.append(byte)
                                if chunk.count == 4_096 {
                                    continuation.yield(chunk)
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            }
                            if !chunk.isEmpty { continuation.yield(chunk) }
                            continuation.finish()
                        } catch {
                            let payload = Self.openAIErrorData(
                                message: error.localizedDescription,
                                type: "proxy_error"
                            )
                            var event = Data("data: ".utf8)
                            event.append(payload)
                            event.append(Data("\n\ndata: [DONE]\n\n".utf8))
                            continuation.yield(event)
                            continuation.finish()
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                return .init(statusCode: status, headers: ["Content-Type": "text/event-stream"], stream: stream)
            }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            if data.isEmpty, !(200...299).contains(status) {
                return Self.openAIError(status: status, message: "Upstream error (\(status))", type: "upstream_error")
            }
            return .init(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch {
            return Self.openAIError(status: 502, message: error.localizedDescription, type: "proxy_error")
        }
    }

    private func promptPair(
        system: String,
        user: String,
        defaults defaultPair: (system: String, user: String)
    ) -> DesktopWebJSONValue {
        .object([
            "system": .string(defaults.string(forKey: system) ?? defaultPair.system),
            "user": .string(defaults.string(forKey: user) ?? defaultPair.user)
        ])
    }

    private func applyProvider(_ value: DesktopWebJSONValue?, apiKey: String, model: String) {
        guard let object = value?.objectValue else { return }
        if let value = object["apiKey"]?.stringValue { defaults.set(value, forKey: apiKey) }
        if let value = object["model"]?.stringValue { defaults.set(value, forKey: model) }
    }

    private func applyPrompt(_ value: DesktopWebJSONValue?, system: String, user: String) {
        guard let object = value?.objectValue else { return }
        if let value = object["system"]?.stringValue { defaults.set(value, forKey: system) }
        if let value = object["user"]?.stringValue { defaults.set(value, forKey: user) }
    }

    private static func openAIError(status: Int, message: String, type: String = "invalid_request_error") -> DesktopWebRawHTTPResponse {
        .init(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: openAIErrorData(message: message, type: type)
        )
    }

    /// 使用 JSONEncoder 序列化 OpenAI 兼容错误体，确保引号、反斜杠、换行和控制字符均合法转义。
    private static func openAIErrorData(
        message: String,
        type: String
    ) -> Data {
        let messageData = (try? JSONEncoder().encode(message)) ?? Data("\"\"".utf8)
        let typeData = (try? JSONEncoder().encode(type)) ?? Data("\"\"".utf8)
        let encodedMessage = String(decoding: messageData, as: UTF8.self)
        let encodedType = String(decoding: typeData, as: UTF8.self)
        return Data(#"{"error":{"message":\#(encodedMessage),"type":\#(encodedType)}}"#.utf8)
    }
}

private extension DesktopWebAIService {
    static let noteDefaults = (
        system: """
        你是一名书摘解析助手，用口语化中文生成一次性解析结果。严格遵循：
        1. 解析结构：
        - 核心观点（1句话概括）
        - 复杂概念必须用「例如：...」说明
        - 不同分析维度之间用空行分隔
        - 不同部分用空行分隔，禁用任何符号/序号

        2. 语言规范：
        - 每段不超过100字，用日常词汇代替术语
        - 保留“可能”“或许”等不确定性词汇

        3. 异常处理：
        - 内容不完整时，开头用“注意：当前内容可能缺少上下文，推测解析如下：”
        - 遇到专业术语时，在例子中说明“文中‘XX’可能指...（简要说明），例如日常中的XX情况”
        - 禁止任何追问，仅基于现有信息解析
        """,
        user: """
        帮用户理解书摘所表达的含义，有必要的话引申一些相关的概念（只有非常有必要的时候，比如要引申的概念与书摘强相关且有必要）
        ［书籍］${书籍名}（作者：${作者名}）
        ［原文摘录］${摘录}
        ［摘录所属章节］${章节}

        要求：
        1. 总结摘录所表达的内容\u{20}\u{20}
        2. 若分析存在多种可能性请并列说明
        3. 对于涉及到的复杂概念举例说明
        4. 保持段落精简（每段≤3行）
        5. 让用户有更多阅读的收获
        """
    )

    static let wordDefaults = (
        system: """
        你是一名语言助手，帮助用户用通俗易懂、口语化的中文解释查询内容，生成一次性解析结果。严格遵循：

        1. 解析结构：
        - 基本信息：
          - 中文单字：如该字较生僻，整体附带拼音，避免逐字拆分
          - 英文单词：附带音标（英式或美式皆可）
        - 中文释义：用简洁直白的语言解释含义，避免生硬术语
        - 用法示例：用简单例子说明含义或常见使用场景
        - 补充说明：仅当有必要，解释词源、搭配、语境差异、易混淆点等

        2. 输入兼容：
        - 查询内容可以是单个字、单词、短语或完整句子
        - 根据具体内容灵活调整解释范围：
          - 单个字：提供整体拼音与含义，若有多义并列说明
          - 单词/短语：提供含义、英文单词附音标，必要时举例
          - 句子：翻译整体意思，必要时解释关键词或表达

        3. 语言规范：
        - 中文解释自然简洁，避免死板照搬词典
        - 遇到外语，优先提供中文翻译与含义解释
        - 用「例如：...」举例，示例务必通俗易懂
        - 多义词需并列清晰说明，避免混淆
        - 适度使用 Emoji 强调重点，避免滥用或影响理解

        4. 异常处理：
        - 信息不完整或不确定时，明确用「可能」或「猜测」提示
        - 遇到俚语、特殊表达或文化背景相关内容，需额外简要说明
        - 禁止任何追问，仅基于现有信息生成解释

        5. 其他要求：
        - 用户提供的书籍名，仅在确实有助于理解时参考
        - 上下文内容仅用于辅助你理解查询内容的含义，你无需对上下文本身进行扩展或分析
        - 整体输出保持简洁实用，避免冗余，控制在 300 字以内
        """,
        user: """
        请帮助用户理解以下查询内容，必要时翻译、解释含义，若有用法差异、词源背景、常见误解也请补充：

        ［查询内容］${查询文本}\u{20}\u{20}
        ［上下文信息］${上下文}\u{20}\u{20}
        ［所属书籍］${书籍名}\u{20}\u{20}

        要求：
        1. 中文单字：如该字较生僻，附带拼音，解释含义与常见词语搭配\u{20}\u{20}
        2. 英文单词：附带音标，解释含义、常见用法，必要时举例\u{20}\u{20}
        3. 短语：解释整体含义，必要时拆分说明\u{20}\u{20}
        4. 句子：翻译整体意思，必要时解释关键词汇或表达\u{20}\u{20}
        5. 内容保持简洁实用，帮助用户快速理解
        6. 禁止追问
        """
    )

    static let autoTagDefaults = (
        // Android 的 const triple-quoted system prompt 未调用 trimIndent，首尾各保留一个换行。
        system: "\n" + """
        你是一个专业的知识管理助手，负责为阅读书摘推荐**对长期知识管理有意义**的标签。

        **核心原则：**
        1. **稳定性优先于细节**：标签应描述书摘中的稳定主题或核心观点，而非局部细节或一次性信息
        2. **精准但不过细**：避免为单一案例、举例说明、术语释义或背景细节创建标签
        3. **合理复用**：若已有标签能够覆盖书摘的核心主题，应优先使用，避免过度拆分
        4. **数量克制**：推荐 1–3 个标签，若不存在明确值得管理的主题，可不推荐标签

        **标签语义要求：**
        - 标签应为「稳定概念 / 方法 / 观点 / 主题」
        - 避免人物称谓、具体事物名称、词语释义或技术细节
        - 避免仅在当前书摘中出现、缺乏复用价值的标签

        **主次与相关性判断：**
        - 并非书摘中出现的所有概念都值得成为标签
        - 若某内容仅用于举例、类比、说明或辅助理解，应忽略
        - 跨领域概念若仅作为说明工具，应优先抽象为更高层主题，或不打标签

        **词语与生僻词规则：**
        - 生僻词本身不等同于知识标签
        - 仅当词语被赋予特定含义，并承担分析或论证作用时，才可作为标签

        请以 JSON 格式返回标签建议。
        """ + "\n",
        user: """
        请为以下书摘内容推荐**对知识管理有长期价值**的标签：

        **书摘内容：**
        ${书摘内容}

        **书籍信息：**
        - 书名：${书籍名}
        - 作者：${作者名}
        - 章节：${章节}

        **用户已有标签列表：**
        ${已有标签}

        **分析步骤：**
        1. 判断书摘是否包含**值得长期管理的稳定主题或观点**
        2. 若内容仅为举例、释义、背景或局部细节，可不推荐标签
        3. 若存在稳定主题，优先复用能够覆盖该主题的已有标签
        4. 仅在已有标签无法表达时，创建更抽象但仍然明确的新标签

        **要求：**
        - 推荐 0–3 个标签
        - 优先推荐稳定、可复用的主题
        - 避免为单一术语、例子或细节创建标签
        - 新标签应简洁（2–6 个字），语义明确，长期有效

        返回 JSON 格式：
        {
          "tags": [
            {
              "name": "标签名称",
              "isExisting": true/false,
              "reason": "说明该主题为何值得作为长期标签，或为何选择复用"
            }
          ]
        }
        """
    )
}
