/**
 * [INPUT]: 依赖 Foundation 提供字符串索引、集合与值语义，接收提示词种类、字段文本和运行时替换值
 * [OUTPUT]: 对外提供提示词字段、变量目录、校验问题、请求预览、含书籍封面的可编辑试运行书摘、流式事件与唯一请求构建器
 * [POS]: Domain/Models 的提示词编辑业务规则层，被 AIRepository 与编辑页共享，确保保存、预览和正式请求使用同一契约
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 用户可切换的提示词字段；界面使用中文名称，内部模型上下文继续保留英文技术名称。
nonisolated enum AIPromptEditorField: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case taskTemplate
    case roleRules

    var id: String { rawValue }

    var displayTitle: LocalizedStringResource {
        switch self {
        case .taskTemplate:
            "用户提示词"
        case .roleRules:
            "系统提示词"
        }
    }

    var technicalTitle: String {
        switch self {
        case .taskTemplate:
            "User Prompt"
        case .roleRules:
            "System Prompt"
        }
    }
}

/// 变量对任务的影响级别；必需变量缺失阻止保存，推荐变量缺失只提示结果风险。
nonisolated enum AIPromptVariableRequirement: String, Codable, Hashable, Sendable {
    case required
    case recommended
}

/// 变量的弱色彩分组；颜色仅辅助区分来源，不承担必需或已插入状态表达。
nonisolated enum AIPromptVariableCategory: String, Codable, Hashable, Sendable {
    case content
    case context
    case metadata
}

/// 任务模板支持的运行时变量定义，持久化占位符始终保持 `${变量名}` 纯文本格式。
nonisolated struct AIPromptVariableDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
    let name: String
    let requirement: AIPromptVariableRequirement
    let category: AIPromptVariableCategory

    var id: String { name }
    var placeholder: String { "${\(name)}" }

    var accessibilityRequirement: String {
        requirement == .required ? "必需" : "推荐"
    }
}

/// 以字符偏移表达的可定位文本范围，避免跨层传递不稳定的 String.Index。
nonisolated struct AIPromptTextRange: Codable, Equatable, Hashable, Sendable {
    let location: Int
    let length: Int
}

/// 提示词问题严重度；只有 error 阻止保存或正式请求。
nonisolated enum AIPromptValidationSeverity: Int, Codable, Comparable, Sendable {
    case information
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 可聚合统计且不包含用户正文的校验问题类型。
nonisolated enum AIPromptValidationIssueKind: Equatable, Hashable, Sendable {
    case empty
    case missingRequired(String)
    case missingRecommended(String)
    case unknownVariable(String)
    case incompleteVariable
    case roleVariableSyntax
}

/// 保存前与运行前共用的提示词问题，范围用于编辑器直接选中错误位置。
nonisolated struct AIPromptValidationIssue: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let field: AIPromptEditorField
    let severity: AIPromptValidationSeverity
    let kind: AIPromptValidationIssueKind
    let message: String
    let range: AIPromptTextRange?

    var blocksSaving: Bool { severity == .error }
}

/// 离线预览和网络请求共用的最终消息；应用协议独立保留，默认界面无需展示。
nonisolated struct AIPromptRequestPreview: Equatable, Sendable {
    let kind: AIPromptKind
    let systemPrompt: String
    let userPrompt: String
    let applicationRules: String
    let expectsJSON: Bool
}

/// 试运行上下文只携带变量值与来源标题，不持有或记录额外用户输入。
nonisolated struct AIPromptSampleContext: Equatable, Sendable {
    let title: String
    let replacements: [String: String]
}

/// 提示词试运行使用的可编辑书摘快照；本地记录后续变化不会改写已经打开的测试现场。
nonisolated struct AIPromptTrialExcerpt: Equatable, Sendable {
    let localNoteID: Int64?
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let chapterTitle: String
    let idea: String
    let tagNames: [String]
    let originalText: String

    /// 使用用户选中的本地书摘建立稳定快照；富文本已由 NoteRepository 转换为可见纯文本。
    init(note: NoteExcerptListItem) {
        self.localNoteID = note.id
        self.bookTitle = note.bookTitle
        self.bookAuthor = note.bookAuthor
        self.bookCoverURL = note.bookCoverURL
        self.chapterTitle = note.chapterTitle
        self.idea = note.plainIdea
        self.tagNames = note.tags.map(\.title)
        self.originalText = note.plainContent
    }

    private init(
        localNoteID: Int64?,
        bookTitle: String,
        bookAuthor: String,
        bookCoverURL: String,
        chapterTitle: String,
        idea: String,
        tagNames: [String],
        originalText: String
    ) {
        self.localNoteID = localNoteID
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.bookCoverURL = bookCoverURL
        self.chapterTitle = chapterTitle
        self.idea = idea
        self.tagNames = tagNames
        self.originalText = originalText
    }

    /// 产品默认试运行书摘；正文与来源固定，避免“示例内容”成为无法解释的抽象来源。
    static let hundredYearsOfSolitude = AIPromptTrialExcerpt(
        localNoteID: nil,
        bookTitle: "百年孤独",
        bookAuthor: "加西亚·马尔克斯",
        bookCoverURL: "",
        chapterTitle: "第一章",
        idea: "第一次读时只觉得“冰块”很神奇，后来才意识到，这句话把死亡、童年和记忆放在了同一个瞬间，也像是在提醒我：人走得再远，仍可能被最初的经验牵引。",
        tagNames: ["记忆", "时间", "命运"],
        originalText: "多年以后，面对行刑队，奥雷里亚诺·布恩迪亚上校将会回想起父亲带他去见识冰块的那个遥远的下午。"
    )

    /// 把可编辑正文与所选书摘元数据映射为当前任务的受控变量，界面无需理解 Prompt 占位符。
    func sampleContext(
        for kind: AIPromptKind,
        editedText: String,
        selectedQuery: String? = nil
    ) -> AIPromptSampleContext {
        let title = bookTitle.isEmpty ? "测试书摘" : bookTitle
        switch kind {
        case .noteExplanation:
            return AIPromptSampleContext(
                title: title,
                replacements: [
                    "摘录": editedText,
                    "想法": idea,
                    "章节": chapterTitle,
                    "书籍名": bookTitle,
                    "作者名": bookAuthor,
                ]
            )
        case .wordLookup:
            return AIPromptSampleContext(
                title: title,
                replacements: [
                    "查询文本": selectedQuery ?? "",
                    "上下文": editedText,
                    "书籍名": bookTitle,
                ]
            )
        case .autoTag:
            return AIPromptSampleContext(
                title: title,
                replacements: [
                    "书摘内容": editedText,
                    "书籍名": bookTitle,
                    "作者名": bookAuthor,
                    "章节": chapterTitle,
                    "已有标签": tagNames.isEmpty
                        ? "暂无已创建的标签"
                        : tagNames.joined(separator: "、"),
                ]
            )
        }
    }
}

/// 对照试运行中的独立输出目标；原始提示词只替换模板，不改变模型、参数或书摘上下文。
nonisolated enum AIPromptTrialTarget: String, CaseIterable, Hashable, Identifiable, Sendable {
    case current
    case appDefault

    var id: String { rawValue }
}

/// 试运行流式事件；单侧失败作为目标事件返回，使另一侧仍能继续生成并保留部分内容。
nonisolated enum AIPromptTrialEvent: Equatable, Sendable {
    case content(target: AIPromptTrialTarget, markdown: String)
    case completed(target: AIPromptTrialTarget)
    case failed(target: AIPromptTrialTarget, error: AIRepositoryError)
}

/// 三类任务的受控变量目录，禁止编辑页生成任意自定义变量。
nonisolated enum AIPromptVariableCatalog {
    static func definitions(for kind: AIPromptKind) -> [AIPromptVariableDefinition] {
        switch kind {
        case .noteExplanation:
            [
                definition("摘录", .required, .content),
                definition("想法", .recommended, .context),
                definition("章节", .recommended, .context),
                definition("书籍名", .recommended, .metadata),
                definition("作者名", .recommended, .metadata),
            ]
        case .wordLookup:
            [
                definition("查询文本", .required, .content),
                definition("上下文", .recommended, .context),
                definition("书籍名", .recommended, .metadata),
            ]
        case .autoTag:
            [
                definition("书摘内容", .required, .content),
                definition("书籍名", .recommended, .metadata),
                definition("作者名", .recommended, .metadata),
                definition("章节", .recommended, .context),
                definition("已有标签", .recommended, .context),
            ]
        }
    }

    private static func definition(
        _ name: String,
        _ requirement: AIPromptVariableRequirement,
        _ category: AIPromptVariableCategory
    ) -> AIPromptVariableDefinition {
        AIPromptVariableDefinition(name: name, requirement: requirement, category: category)
    }
}

/// 无副作用校验器；Repository 保存和请求前再次调用，旧配置也不能静默发送未知变量。
nonisolated enum AIPromptValidator {
    static func issues(
        in text: String,
        field: AIPromptEditorField,
        kind: AIPromptKind
    ) -> [AIPromptValidationIssue] {
        var issues: [AIPromptValidationIssue] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                issue(
                    field: field,
                    severity: .error,
                    kind: .empty,
                    message: "内容不能为空",
                    range: nil,
                    suffix: "empty"
                )
            )
        }

        let tokens = parsedTokens(in: text)
        if field == .roleRules {
            if !tokens.isEmpty || text.contains("${") {
                let firstRange = tokens.first?.range ?? incompleteRange(in: text)
                issues.append(
                    issue(
                        field: field,
                        severity: .information,
                        kind: .roleVariableSyntax,
                        message: "这里的变量不会自动替换",
                        range: firstRange,
                        suffix: "literal"
                    )
                )
            }
            return issues
        }

        let definitions = AIPromptVariableCatalog.definitions(for: kind)
        let knownNames = Set(definitions.map(\.name))
        var insertedKnownNames = Set<String>()

        for token in tokens {
            if knownNames.contains(token.name) {
                insertedKnownNames.insert(token.name)
            } else {
                let shownName = token.name.isEmpty ? "空变量" : token.name
                issues.append(
                    issue(
                        field: field,
                        severity: .error,
                        kind: .unknownVariable(token.name),
                        message: "未知变量：\(shownName)",
                        range: token.range,
                        suffix: "unknown-\(token.range.location)"
                    )
                )
            }
        }

        if let range = incompleteRange(in: text) {
            issues.append(
                issue(
                    field: field,
                    severity: .error,
                    kind: .incompleteVariable,
                    message: "变量括号不完整",
                    range: range,
                    suffix: "incomplete-\(range.location)"
                )
            )
        }

        for definition in definitions where !insertedKnownNames.contains(definition.name) {
            switch definition.requirement {
            case .required:
                issues.append(
                    issue(
                        field: field,
                        severity: .error,
                        kind: .missingRequired(definition.name),
                        message: "缺少必需变量：\(definition.name)",
                        range: nil,
                        suffix: "required-\(definition.name)"
                    )
                )
            case .recommended:
                issues.append(
                    issue(
                        field: field,
                        severity: .warning,
                        kind: .missingRecommended(definition.name),
                        message: "未使用 \(definition.name)，结果可能缺少上下文",
                        range: nil,
                        suffix: "recommended-\(definition.name)"
                    )
                )
            }
        }

        return issues.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return (lhs.range?.location ?? .max) < (rhs.range?.location ?? .max)
        }
    }

    static func issues(in template: AIPromptTemplate, kind: AIPromptKind) -> [AIPromptValidationIssue] {
        issues(in: template.user, field: .taskTemplate, kind: kind)
            + issues(in: template.system, field: .roleRules, kind: kind)
    }

    static func blockingIssue(in template: AIPromptTemplate, kind: AIPromptKind) -> AIPromptValidationIssue? {
        issues(in: template, kind: kind).first(where: \.blocksSaving)
    }

    static func recognizedTokenRanges(in text: String, kind: AIPromptKind) -> [AIPromptTextRange] {
        let knownNames = Set(AIPromptVariableCatalog.definitions(for: kind).map(\.name))
        return parsedTokens(in: text).filter { knownNames.contains($0.name) }.map(\.range)
    }

    private struct ParsedToken {
        let name: String
        let range: AIPromptTextRange
    }

    private static func parsedTokens(in text: String) -> [ParsedToken] {
        var result: [ParsedToken] = []
        var cursor = text.startIndex
        while let start = text.range(of: "${", range: cursor..<text.endIndex)?.lowerBound {
            let nameStart = text.index(start, offsetBy: 2)
            guard let close = text[nameStart...].firstIndex(of: "}") else { break }
            let end = text.index(after: close)
            result.append(
                ParsedToken(
                    name: String(text[nameStart..<close]),
                    range: makeRange(start..<end, in: text)
                )
            )
            cursor = end
        }
        return result
    }

    private static func incompleteRange(in text: String) -> AIPromptTextRange? {
        var cursor = text.startIndex
        while let start = text.range(of: "${", range: cursor..<text.endIndex)?.lowerBound {
            let nameStart = text.index(start, offsetBy: 2)
            guard let close = text[nameStart...].firstIndex(of: "}") else {
                return makeRange(start..<text.endIndex, in: text)
            }
            cursor = text.index(after: close)
        }
        return nil
    }

    private static func makeRange(
        _ range: Range<String.Index>,
        in text: String
    ) -> AIPromptTextRange {
        AIPromptTextRange(
            location: text.distance(from: text.startIndex, to: range.lowerBound),
            length: text.distance(from: range.lowerBound, to: range.upperBound)
        )
    }

    private static func issue(
        field: AIPromptEditorField,
        severity: AIPromptValidationSeverity,
        kind: AIPromptValidationIssueKind,
        message: String,
        range: AIPromptTextRange?,
        suffix: String
    ) -> AIPromptValidationIssue {
        AIPromptValidationIssue(
            id: "\(field.rawValue)-\(suffix)",
            field: field,
            severity: severity,
            kind: kind,
            message: message,
            range: range
        )
    }
}

/// 唯一请求构建器；所有调用都先校验任务模板，再替换变量并追加不可编辑协议。
nonisolated enum AIPromptRequestBuilder {
    static func preview(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        replacements: [String: String]
    ) throws -> AIPromptRequestPreview {
        if let issue = AIPromptValidator.blockingIssue(in: template, kind: kind) {
            throw AIRepositoryError.invalidConfiguration("\(kind.title)：\(issue.message)")
        }

        let renderedUser = AIPromptVariableCatalog.definitions(for: kind).reduce(template.user) {
            partial, definition in
            partial.replacingOccurrences(
                of: definition.placeholder,
                with: replacements[definition.name] ?? ""
            )
        }
        let rules = applicationRules(for: kind)
        return AIPromptRequestPreview(
            kind: kind,
            systemPrompt: "\(template.system)\n\n\(rules)",
            userPrompt: renderedUser,
            applicationRules: rules,
            expectsJSON: kind == .autoTag
        )
    }

    static func builtInSample(for kind: AIPromptKind) -> AIPromptSampleContext {
        let excerpt = AIPromptTrialExcerpt.hundredYearsOfSolitude
        return excerpt.sampleContext(
            for: kind,
            editedText: excerpt.originalText,
            selectedQuery: kind == .wordLookup ? "冰块" : nil
        )
    }

    static func applicationRules(for kind: AIPromptKind) -> String {
        switch kind {
        case .noteExplanation:
            """
            以下为应用固定的展示格式，若与前文冲突，以此处为准：
            - 使用标准 Markdown，不输出一级标题、原始 HTML 或整篇代码围栏。
            - 必须先输出「## 核心观点」，再输出「## 解析」。
            - 只有存在多个并列观点时才使用无序列表；重点词可少量加粗。
            - 「## 不同理解」和「## 延伸思考」仅在确有需要时输出，不输出空章节。
            """
        case .wordLookup:
            """
            以下为应用固定的展示格式，若与前文冲突，以此处为准：
            - 使用标准 Markdown，不输出一级标题、原始 HTML 或整篇代码围栏。
            - 必须输出「## 释义」和「## 用法示例」。
            - 「## 基本信息」和「## 补充说明」仅在确有需要时输出，不输出空章节。
            - 多个含义或用法使用无序列表，重点词可少量加粗。
            """
        case .autoTag:
            """
            以下为应用固定的结构化输出协议，若与前文冲突，以此处为准：
            - 只返回一个有效 JSON 对象，不输出 Markdown、代码围栏或额外说明。
            - 顶层只使用 tags 数组；可返回 0–3 项。
            - 每项必须包含 name 字符串，可包含 isExisting 布尔值与 reason 字符串。
            - 固定结构：{"tags":[{"name":"标签名称","isExisting":true,"reason":"推荐或复用原因"}]}
            """
        }
    }
}
