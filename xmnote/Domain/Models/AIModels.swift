/**
 * [INPUT]: 依赖 Foundation 提供 Codable、URL 与本地化错误语义
 * [OUTPUT]: 对外提供 AIProvider 模型目录与展示名、AIConfiguration、三套 Prompt、选词释义输入、AI 标签流事件/建议与统一错误模型
 * [POS]: Domain/Models 的 AI 业务模型，隔离设置页、Viewer、Repository 与 OpenAI-compatible 网络细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android 已开放的 AI 供应商；基础地址固定为同源生产地址，用户密钥由 Keychain 单独保存。
nonisolated enum AIProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case deepSeek
    case siliconFlow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeek:
            "DeepSeek"
        case .siliconFlow:
            "SiliconFlow"
        }
    }

    var baseURLString: String {
        switch self {
        case .deepSeek:
            "https://api.deepseek.com/"
        case .siliconFlow:
            "https://api.siliconflow.cn/"
        }
    }

    var modelOptions: [AIModelOption] {
        switch self {
        case .deepSeek:
            [
                AIModelOption(id: "deepseek-v4-flash", title: "DeepSeek V4 Flash"),
                AIModelOption(id: "deepseek-v4-pro", title: "DeepSeek V4 Pro"),
            ]
        case .siliconFlow:
            [
                AIModelOption(id: "deepseek-ai/DeepSeek-V3", title: "DeepSeek-V3"),
                AIModelOption(id: "meta-llama/Llama-3.3-70B-Instruct", title: "Llama-3.3-70B-Instruct"),
                AIModelOption(id: "Qwen/QwQ-32B-Preview", title: "QwQ-32B-Preview"),
            ]
        }
    }

    var defaultModelID: String {
        modelOptions.first?.id ?? ""
    }

    /// 将请求 ID 转为界面展示名；异常值按当前供应商默认模型降级展示。
    func modelTitle(for modelID: String) -> String {
        modelOptions.first(where: { $0.id == modelID })?.title
            ?? modelOptions.first?.title
            ?? modelID
    }
}

/// 供应商模型选项，分别保留真实请求 ID 与设置页展示名。
nonisolated struct AIModelOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
}

/// 三类可编辑 Prompt，身份同时用于设置页 Sheet 与默认值恢复。
nonisolated enum AIPromptKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case noteExplanation
    case wordLookup
    case autoTag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noteExplanation:
            "AI 释义"
        case .wordLookup:
            "AI 查词"
        case .autoTag:
            "AI 标签"
        }
    }

    var subtitle: String {
        switch self {
        case .noteExplanation:
            "让 AI 解释这段书摘的含义"
        case .wordLookup:
            "解释正文中选中的字、词、短语或句子"
        case .autoTag:
            "推荐适合长期知识管理的标签"
        }
    }
}

/// 一套 AI 任务的 system/user Prompt。
nonisolated struct AIPromptTemplate: Codable, Equatable, Sendable {
    var system: String
    var user: String
}

/// Android 同源的三套业务 Prompt；文本任务补充标准 Markdown 输出契约，便于流式预览形成稳定阅读层级。
nonisolated struct AIPromptConfiguration: Codable, Equatable, Sendable {
    var noteExplanation: AIPromptTemplate
    var wordLookup: AIPromptTemplate
    var autoTag: AIPromptTemplate

    func template(for kind: AIPromptKind) -> AIPromptTemplate {
        switch kind {
        case .noteExplanation:
            noteExplanation
        case .wordLookup:
            wordLookup
        case .autoTag:
            autoTag
        }
    }

    mutating func setTemplate(_ template: AIPromptTemplate, for kind: AIPromptKind) {
        switch kind {
        case .noteExplanation:
            noteExplanation = template
        case .wordLookup:
            wordLookup = template
        case .autoTag:
            autoTag = template
        }
    }

    mutating func reset(_ kind: AIPromptKind) {
        setTemplate(Self.androidAlignedDefault.template(for: kind), for: kind)
    }

    static let androidAlignedDefault = AIPromptConfiguration(
        noteExplanation: AIPromptTemplate(
            system: """
            你是一名书摘解析助手，用口语化中文生成一次性解析结果。严格遵循：
            1. 输出格式：
            - 使用标准 Markdown，不输出一级标题、原始 HTML 或整篇代码围栏
            - 固定先输出「## 核心观点」，用 1 句话概括
            - 随后根据内容选用「## 解析」「## 不同理解」「## 延伸思考」中的 1–3 个二级标题，不输出空章节
            - 并列观点使用无序列表，重点词可少量加粗；不要为了展示格式强行使用表格、代码块或引用
            - 复杂概念用「例如：...」开头的普通段落说明

            2. 语言规范：
            - 每段不超过100字，用日常词汇代替术语
            - 保留“可能”“或许”等不确定性词汇

            3. 异常处理：
            - 内容不完整时，开头用“注意：当前内容可能缺少上下文，推测解析如下：”
            - 遇到专业术语时，在例子中说明“文中‘XX’可能指...（简要说明），例如日常中的XX情况”
            - 禁止任何追问，仅基于现有信息解析
            """,
            user: """
            帮用户理解书摘所表达的含义，有必要的话引申一些与书摘强相关且确有必要的概念。
            ［书籍］${书籍名}（作者：${作者名}）
            ［原文摘录］${摘录}
            ［用户想法］${想法}
            ［摘录所属章节］${章节}

            要求：
            1. 总结摘录所表达的内容
            2. 若分析存在多种可能性请并列说明
            3. 对于涉及到的复杂概念举例说明
            4. 保持段落精简（每段≤3行）
            5. 让用户有更多阅读的收获
            6. 遵循系统要求的 Markdown 层级，不重复输出书名或「AI 释义」标题
            """
        ),
        wordLookup: AIPromptTemplate(
            system: """
            你是一名语言助手，帮助用户用通俗易懂、口语化的中文解释查询内容，生成一次性解析结果。严格遵循：

            1. 输出格式：
            - 使用标准 Markdown，不输出一级标题、原始 HTML 或整篇代码围栏
            - 根据查询内容选用「## 基本信息」「## 释义」「## 用法示例」「## 补充说明」二级标题，不输出空章节
            - 多个含义或用法使用无序列表，重点词可少量加粗；不要为了展示格式强行使用表格、代码块或引用

            2. 解析结构：
            - 基本信息：中文生僻字整体附带拼音；英文单词附带英式或美式音标
            - 释义：用简洁直白的语言解释含义
            - 用法示例：用简单例子说明含义或常见使用场景
            - 补充说明：仅在必要时解释词源、搭配、语境差异或易混淆点

            3. 输入兼容：查询内容可以是单字、单词、短语或完整句子，并按内容灵活调整解释范围。
            4. 语言规范：自然简洁，多义词并列说明，用「例如：...」举例，可适度使用 Emoji。
            5. 信息不完整时明确使用「可能」或「猜测」，禁止追问。
            6. 书籍名和上下文只用于辅助理解，整体控制在 300 字以内。
            """,
            user: """
            请帮助用户理解以下查询内容，必要时翻译、解释含义，若有用法差异、词源背景、常见误解也请补充：

            ［查询内容］${查询文本}
            ［上下文信息］${上下文}
            ［所属书籍］${书籍名}

            要求：
            1. 中文单字：生僻字附带拼音，解释含义与常见搭配
            2. 英文单词：附带音标，解释含义、常见用法，必要时举例
            3. 短语：解释整体含义，必要时拆分说明
            4. 句子：翻译整体意思，必要时解释关键词汇或表达
            5. 内容保持简洁实用，禁止追问
            6. 遵循系统要求的 Markdown 层级，不重复输出查询内容作为一级标题
            """
        ),
        autoTag: AIPromptTemplate(
            system: """
            你是一个专业的知识管理助手，负责为阅读书摘推荐对长期知识管理有意义的标签。

            核心原则：稳定性优先于细节；精准但不过细；已有标签能够覆盖时优先复用；推荐 1–3 个，主题不明确时可不推荐。
            标签应为稳定概念、方法、观点或主题，避免人物称谓、具体事物、词语释义、单一案例和一次性细节。
            若内容只用于举例、类比、说明或辅助理解，应忽略或抽象为更高层主题。
            生僻词本身不等同于知识标签，除非它承担明确的分析或论证作用。
            请只以 JSON 格式返回标签建议。
            """,
            user: """
            请为以下书摘内容推荐对知识管理有长期价值的标签：

            ［书摘内容］${书摘内容}
            ［书名］${书籍名}
            ［作者］${作者名}
            ［章节］${章节}
            ［用户已有标签］${已有标签}

            要求：推荐 0–3 个标签，优先复用稳定主题；新标签保持 2–6 个字、语义明确且长期有效。
            只返回以下 JSON：
            {"tags":[{"name":"标签名称","isExisting":true,"reason":"推荐或复用原因"}]}
            """
        )
    )
}

/// 非敏感 AI 配置；API Key 不进入该模型，也不会写入 UserDefaults 或备份文件。
nonisolated struct AIConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var provider: AIProvider
    var deepSeekModelID: String
    var siliconFlowModelID: String
    var prompts: AIPromptConfiguration

    func modelID(for provider: AIProvider) -> String {
        switch provider {
        case .deepSeek:
            deepSeekModelID
        case .siliconFlow:
            siliconFlowModelID
        }
    }

    mutating func setModelID(_ modelID: String, for provider: AIProvider) {
        switch provider {
        case .deepSeek:
            deepSeekModelID = modelID
        case .siliconFlow:
            siliconFlowModelID = modelID
        }
    }

    var selectedModelID: String {
        modelID(for: provider)
    }

    var selectedModelTitle: String {
        provider.modelTitle(for: selectedModelID)
    }

    var normalized: AIConfiguration {
        var result = self
        for provider in AIProvider.allCases {
            let validIDs = Set(provider.modelOptions.map(\.id))
            if !validIDs.contains(result.modelID(for: provider)) {
                result.setModelID(provider.defaultModelID, for: provider)
            }
        }
        return result
    }

    static let androidAlignedDefault = AIConfiguration(
        isEnabled: true,
        provider: .deepSeek,
        deepSeekModelID: AIProvider.deepSeek.defaultModelID,
        siliconFlowModelID: AIProvider.siliconFlow.defaultModelID,
        prompts: .androidAlignedDefault
    )
}

/// 设置页只读取“是否存在密钥”，绝不把 Keychain 明文回填到界面状态。
nonisolated struct AIConfigurationSnapshot: Equatable, Sendable {
    let configuration: AIConfiguration
    let providersWithStoredKey: Set<AIProvider>

    func hasStoredKey(for provider: AIProvider) -> Bool {
        providersWithStoredKey.contains(provider)
    }
}

/// Viewer 选词释义输入，锁定触发时选择文本、上下文和所属书籍，避免翻页后串写。
nonisolated struct AITextLookupInput: Equatable, Sendable {
    let queryText: String
    let queryContext: String
    let bookTitle: String
}

/// 自动标签候选；首项默认选中与 Android 保持一致，用户可在应用前调整选择。
nonisolated struct AIAutoTagSuggestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isExisting: Bool
    let reason: String
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        name: String,
        isExisting: Bool,
        reason: String,
        isSelected: Bool
    ) {
        self.id = id
        self.name = name
        self.isExisting = isExisting
        self.reason = reason
        self.isSelected = isSelected
    }
}

/// AI 标签生成流的领域事件；正文快照供 Markdown 增量展示，完成事件只携带 Repository 校准后的最终候选。
nonisolated enum AIAutoTagGenerationEvent: Equatable, Sendable {
    case content(String)
    case completed([AIAutoTagSuggestion])
}

/// AI 配置、网络和业务写入的统一用户可读错误。
nonisolated enum AIRepositoryError: LocalizedError, Equatable, Sendable {
    case disabled
    case missingAPIKey(AIProvider)
    case invalidConfiguration(String)
    case noteNotFound
    case unauthorized
    case forbidden
    case rateLimited
    case service(statusCode: Int)
    case network(String)
    case emptyResponse
    case invalidAutoTagResponse
    case noTagsSelected
    case credentialStore(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "AI 功能尚未启用，请先前往“我的 > AI 配置”开启。"
        case .missingAPIKey(let provider):
            "尚未配置 \(provider.displayName) API Key。"
        case .invalidConfiguration(let message):
            message
        case .noteNotFound:
            "书摘不存在或已被删除。"
        case .unauthorized:
            "AI 密钥无效，请检查配置。"
        case .forbidden:
            "AI 账户余额不足、无权访问该模型或已受限。"
        case .rateLimited:
            "AI 请求过于频繁，请稍后再试。"
        case .service(let statusCode):
            "AI 服务暂时不可用（HTTP \(statusCode)）。"
        case .network(let message):
            "AI 连接失败：\(message)"
        case .emptyResponse:
            "AI 没有返回可用内容，请检查模型和密钥配置。"
        case .invalidAutoTagResponse:
            "结果格式有误，请重试。"
        case .noTagsSelected:
            "请至少选择一个标签。"
        case .credentialStore(let message):
            "安全存储访问失败：\(message)"
        }
    }
}
