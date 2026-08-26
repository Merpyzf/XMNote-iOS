import Foundation
import SwiftParser
import SwiftSyntax

public enum ReportDisposition: String, Codable, Equatable, Sendable {
    case inventory
    case candidate
}

public struct LintDiagnostic: Codable, Equatable, Sendable {
    public let ruleID: String
    public let path: String
    public let line: Int
    public let column: Int
    public let declaration: String
    public let evidence: String
    public let message: String
    public let reportDisposition: ReportDisposition?
    public let reportGroup: String?

    public init(
        ruleID: String,
        path: String,
        line: Int,
        column: Int,
        declaration: String,
        evidence: String,
        message: String,
        reportDisposition: ReportDisposition? = nil,
        reportGroup: String? = nil
    ) {
        self.ruleID = ruleID
        self.path = path
        self.line = line
        self.column = column
        self.declaration = declaration
        self.evidence = evidence
        self.message = message
        self.reportDisposition = reportDisposition
        self.reportGroup = reportGroup
    }
}

/// Exact owner paths for one family of low-level construction APIs.
public struct ConstructionPolicy: Codable, Equatable, Sendable {
    public let ruleID: String
    public let entryPoints: [String]
    public let allowedPaths: [String]

    public init(ruleID: String, entryPoints: [String], allowedPaths: [String]) {
        self.ruleID = ruleID
        self.entryPoints = entryPoints
        self.allowedPaths = allowedPaths
    }
}

/// Low-level constructors whose owners are configured by the repository policy.
public struct ConstructionPolicies: Codable, Equatable, Sendable {
    public let rawColor: ConstructionPolicy
    public let rawTypography: ConstructionPolicy

    public init(rawColor: ConstructionPolicy, rawTypography: ConstructionPolicy) {
        self.rawColor = rawColor
        self.rawTypography = rawTypography
    }
}

/// Restricts fully-qualified member symbols to explicitly registered owner files.
public struct SymbolPolicy: Codable, Equatable, Sendable {
    public let name: String
    public let ruleID: String
    public let symbols: [String]
    public let allowedPaths: [String]
    public let replacement: String
    public let matchInferred: Bool?

    public init(
        name: String,
        ruleID: String,
        symbols: [String],
        allowedPaths: [String],
        replacement: String,
        matchInferred: Bool = false
    ) {
        self.name = name
        self.ruleID = ruleID
        self.symbols = symbols
        self.allowedPaths = allowedPaths
        self.replacement = replacement
        self.matchInferred = matchInferred
    }
}

/// Blocks business-layer identifiers from leaking into configured lower-level source roots.
public struct DependencyPolicy: Codable, Equatable, Sendable {
    public let name: String
    public let ruleID: String
    public let pathPrefixes: [String]
    public let forbiddenExactIdentifiers: [String]
    public let forbiddenIdentifierSuffixes: [String]

    public init(
        name: String,
        ruleID: String,
        pathPrefixes: [String],
        forbiddenExactIdentifiers: [String],
        forbiddenIdentifierSuffixes: [String]
    ) {
        self.name = name
        self.ruleID = ruleID
        self.pathPrefixes = pathPrefixes
        self.forbiddenExactIdentifiers = forbiddenExactIdentifiers
        self.forbiddenIdentifierSuffixes = forbiddenIdentifierSuffixes
    }
}

/// Declaration-level exception for a custom tap gesture whose semantics cannot be represented by a native control.
public struct GestureException: Codable, Equatable, Sendable {
    public let path: String
    public let declaration: String
    public let reason: String
    public let owner: String
    public let accessibilityAlternative: String
    public let visualFreezeRationale: String

    public init(
        path: String,
        declaration: String,
        reason: String,
        owner: String,
        accessibilityAlternative: String,
        visualFreezeRationale: String
    ) {
        self.path = path
        self.declaration = declaration
        self.reason = reason
        self.owner = owner
        self.accessibilityAlternative = accessibilityAlternative
        self.visualFreezeRationale = visualFreezeRationale
    }
}

/// Repository-owned interaction semantics and the unique 44pt token owner.
public struct InteractionPolicy: Codable, Equatable, Sendable {
    public let tapGestureRuleID: String
    public let touchTargetRuleID: String
    public let touchTargetOwnerPath: String
    public let touchTargetLiteral: Double
    public let touchTargetNameFragments: [String]
    public let gestureExceptions: [GestureException]

    public init(
        tapGestureRuleID: String,
        touchTargetRuleID: String,
        touchTargetOwnerPath: String,
        touchTargetLiteral: Double,
        touchTargetNameFragments: [String],
        gestureExceptions: [GestureException]
    ) {
        self.tapGestureRuleID = tapGestureRuleID
        self.touchTargetRuleID = touchTargetRuleID
        self.touchTargetOwnerPath = touchTargetOwnerPath
        self.touchTargetLiteral = touchTargetLiteral
        self.touchTargetNameFragments = touchTargetNameFragments
        self.gestureExceptions = gestureExceptions
    }
}

/// Swift-facing subset of `policy.json`; unrelated orchestrator fields are ignored by Codable.
public struct LintPolicy: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let constructionPolicies: ConstructionPolicies
    public let symbolPolicies: [SymbolPolicy]
    public let dependencyPolicies: [DependencyPolicy]
    public let interactionPolicy: InteractionPolicy

    public init(
        schemaVersion: Int,
        constructionPolicies: ConstructionPolicies,
        symbolPolicies: [SymbolPolicy],
        dependencyPolicies: [DependencyPolicy] = [],
        interactionPolicy: InteractionPolicy = InteractionPolicy(
            tapGestureRuleID: "DS009",
            touchTargetRuleID: "DS010",
            touchTargetOwnerPath: "xmnote/Utilities/DesignSystem/InteractionMetrics.swift",
            touchTargetLiteral: 44,
            touchTargetNameFragments: ["touch", "hit", "tap"],
            gestureExceptions: []
        )
    ) {
        self.schemaVersion = schemaVersion
        self.constructionPolicies = constructionPolicies
        self.symbolPolicies = symbolPolicies
        self.dependencyPolicies = dependencyPolicies
        self.interactionPolicy = interactionPolicy
    }
}

/// Parses production Swift source and emits design-system diagnostics anchored to syntax nodes.
public struct RuleEngine: Sendable {
    private let policy: LintPolicy

    public init(policy: LintPolicy) {
        self.policy = policy
    }

    /// Lints one source file without reading global state, so callers can batch or test deterministically.
    public func lint(source: String, path: String) -> [LintDiagnostic] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = DesignRuleVisitor(path: path, converter: converter, policy: policy)
        visitor.walk(tree)
        return visitor.diagnostics.sorted {
            ($0.line, $0.column, $0.ruleID) < ($1.line, $1.column, $1.ruleID)
        }
    }
}

private final class DesignRuleVisitor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private let policy: LintPolicy
    private(set) var diagnostics: [LintDiagnostic] = []

    init(path: String, converter: SourceLocationConverter, policy: LintPolicy) {
        self.path = path
        self.converter = converter
        self.policy = policy
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        guard path.hasPrefix("xmnote/Domain/") else { return .skipChildren }
        let importedModule = node.path.trimmedDescription
        if importedModule == "SwiftUI" || importedModule == "UIKit" {
            append(
                ruleID: "DS007",
                node: node,
                message: "Domain 不得依赖 UI 框架；请把视觉映射移到 UI 层。"
            )
        }
        return .skipChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.baseName.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        appendDependencyViolationIfNeeded(identifier: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        let baseName = callee.split(separator: ".").last.map(String.init) ?? callee
        let arguments = node.arguments.trimmedDescription

        appendTouchTargetCallViolationIfNeeded(node, baseName: baseName)

        if baseName == "onTapGesture", isProductionPath {
            let declaration = enclosingDeclarationIdentifier(for: Syntax(node))
            let isRegisteredException = policy.interactionPolicy.gestureExceptions.contains {
                $0.path == path && $0.declaration == declaration
            }
            if !isRegisteredException {
                append(
                    ruleID: policy.interactionPolicy.tapGestureRuleID,
                    node: node,
                    message: "普通点击应使用 Button 等原生语义控件；复杂手势必须登记到声明级例外。",
                    reportDisposition: .candidate,
                    reportGroup: "tap-gesture|\(declaration)"
                )
            }
        }

        let constructsSwiftUIFont = baseName == "font" && arguments.contains(".system(")
        let constructsUIKitFont = callee == ".systemFont"
            || callee == ".boldSystemFont"
            || callee.hasSuffix("UIFont.systemFont")
            || callee.hasSuffix("UIFont.boldSystemFont")
        if !isAllowedOwner(for: policy.constructionPolicies.rawTypography),
           (constructsUIKitFont || (constructsSwiftUIFont && !isImageGlyphFontCall(node))) {
            append(
                ruleID: policy.constructionPolicies.rawTypography.ruleID,
                node: node,
                message: "生产文本不得直接构造固定系统字体；请使用 AppTypography 或页面级排版 token。"
            )
        }

        if baseName == "padding" || baseName == "lineSpacing" {
            if containsDirectNumericLiteral(node.arguments) {
                append(
                    ruleID: "DS002",
                    node: node,
                    message: "布局间距不得直接使用数字；请使用 Spacing 或明确的页面级组合 token。"
                )
            }
        } else if Self.stackConstructors.contains(baseName),
                  let spacingArgument = node.arguments.first(where: { $0.label?.text == "spacing" }),
                  containsDirectNumericLiteral(spacingArgument.expression) {
            append(
                ruleID: "DS002",
                node: node,
                message: "Stack spacing 不得直接使用数字；请使用 Spacing token。"
            )
        }

        if (baseName == "Color" || baseName == "UIColor"),
           (!node.arguments.isEmpty || node.trailingClosure != nil),
           !isAllowedOwner(for: policy.constructionPolicies.rawColor) {
            append(
                ruleID: policy.constructionPolicies.rawColor.ruleID,
                node: node,
                message: "页面与组件不得直接构造颜色；请使用语义色或集中式颜色构造能力。"
            )
        }

        if Self.cornerConstructors.contains(baseName), containsNumericCornerLiteral(node) {
            append(
                ruleID: "DS004",
                node: node,
                message: "表面圆角不得直接使用数字；请使用 CornerRadius token 并保留 continuous 语义。"
            )
        }

        if baseName == "scrollBounceBehavior", arguments.contains(".basedOnSize") {
            append(
                ruleID: "DS005",
                node: node,
                message: "应用自有滚动容器必须使用 always 回弹策略，禁止 basedOnSize。"
            )
        }

        if baseName == "alert", isProductionPath {
            append(
                ruleID: "DS006",
                node: node,
                message: "生产路径中心弹窗必须使用 XMSystemAlert。"
            )
        }

        if (baseName == "Image" || baseName == "Label"),
           let symbol = literalSystemImageName(node) {
            append(
                ruleID: "DSR001",
                node: node,
                message: "SF Symbol 已登记到观察库存；返回与顶部操作等强语义仍由独立规则约束。",
                reportDisposition: .inventory,
                reportGroup: "sf-symbol|\(reportModule)|\(symbol)"
            )
        }

        if Self.animationConstructors.contains(baseName), containsDurationLiteral(node) {
            let classification = motionReportClassification(for: node)
            append(
                ruleID: "DSR002",
                node: node,
                message: classification.disposition == .inventory
                    ? "动画时长已归属明确的局部运动语义或 Reduce Motion 分支。"
                    : "内联动画时长尚无明确运动 owner；请确认 Reduce Motion 替代表达并归入局部语义。",
                reportDisposition: classification.disposition,
                reportGroup: classification.group
            )
        }

        if baseName == "ProgressView", isProductionPath {
            let classification = progressReportClassification(for: node)
            append(
                ruleID: "DSR003",
                node: node,
                message: classification.disposition == .inventory
                    ? "ProgressView 已归入明确的进度或操作反馈语义。"
                    : "ProgressView 尚未归类；读取主态应使用项目加载反馈组件，写操作需明确即时反馈 owner。",
                reportDisposition: classification.disposition,
                reportGroup: classification.group
            )
        }

        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let matchingPolicies = matchingSymbolPolicies(for: node)
        guard let symbolPolicy = matchingPolicies.first(where: { !$0.allowedPaths.contains(path) }) else {
            return .visitChildren
        }
        let matchedSymbols = matchingPolicies
            .flatMap(\.symbols)
            .filter { $0.hasSuffix(".\(node.declName.baseName.text)") }
            .joined(separator: " / ")
        append(
            ruleID: symbolPolicy.ruleID,
            node: node,
            message: "\(matchedSymbols) 只能由已登记 owner 使用；请改用 \(symbolPolicy.replacement)。"
        )
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        appendTouchTargetViolationIfNeeded(node)

        guard declaresStaticTypeMember(node.modifiers),
              let owner = enclosingTypeOwner(for: Syntax(node)) else {
            return .visitChildren
        }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            appendRestrictedDeclarationIfNeeded(
                owner: owner,
                member: identifier.identifier.text,
                node: node
            )
        }
        return .visitChildren
    }

    private func appendDependencyViolationIfNeeded(
        identifier: String,
        node: some SyntaxProtocol
    ) {
        guard let dependencyPolicy = policy.dependencyPolicies.first(where: { item in
            item.pathPrefixes.contains(where: path.hasPrefix)
                && (item.forbiddenExactIdentifiers.contains(identifier)
                    || item.forbiddenIdentifierSuffixes.contains(where: identifier.hasSuffix))
        }) else {
            return
        }
        append(
            ruleID: dependencyPolicy.ruleID,
            node: node,
            message: "UIComponents 不得依赖 \(identifier)；业务状态与数据编排应归还 Feature/ViewModel。",
            reportDisposition: .candidate,
            reportGroup: "dependency|\(dependencyPolicy.name)|\(identifier)"
        )
    }

    private func appendTouchTargetViolationIfNeeded(_ node: VariableDeclSyntax) {
        guard path != policy.interactionPolicy.touchTargetOwnerPath else { return }
        let fragments = policy.interactionPolicy.touchTargetNameFragments.map { $0.lowercased() }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }
            let name = identifier.identifier.text
            let normalizedName = name.lowercased()
            guard fragments.contains(where: normalizedName.contains) else {
                continue
            }
            if containsNumericLiteral(
                binding,
                equalTo: policy.interactionPolicy.touchTargetLiteral
            ) {
                append(
                    ruleID: policy.interactionPolicy.touchTargetRuleID,
                    node: binding,
                    message: "交互语义 44pt 只能由 InteractionMetrics.minimumTouchTarget 持有；请改用唯一 token。",
                    reportDisposition: .candidate,
                    reportGroup: "touch-target|\(name)"
                )
                continue
            }

            let strongInteractionFragments = ["touch", "hit", "tap"]
            let dimensionSuffixes = ["size", "width", "height", "diameter", "target"]
            guard strongInteractionFragments.contains(where: normalizedName.contains),
                  dimensionSuffixes.contains(where: normalizedName.hasSuffix),
                  let initializer = binding.initializer,
                  let literal = directNumericLiteralValue(initializer.value),
                  literal >= 0,
                  literal < policy.interactionPolicy.touchTargetLiteral else {
                continue
            }
            append(
                ruleID: policy.interactionPolicy.touchTargetRuleID,
                node: binding,
                message: "交互命中尺寸不得小于 44pt；视觉尺寸请单独命名，并使用 InteractionMetrics.minimumTouchTarget 承载命中区。",
                reportDisposition: .candidate,
                reportGroup: "undersized-touch-target|\(name)"
            )
        }
    }

    /// 拦截把 44pt 直接写进交互尺寸 API 的做法；纯视觉 44pt 应先归入局部 Metrics，再由调用点引用。
    private func appendTouchTargetCallViolationIfNeeded(
        _ node: FunctionCallExprSyntax,
        baseName: String
    ) {
        guard isProductionPath,
              path != policy.interactionPolicy.touchTargetOwnerPath else {
            return
        }

        let relevantLabels: Set<String>
        switch baseName {
        case "frame":
            relevantLabels = ["width", "height", "minWidth", "minHeight"]
        case "constraint":
            relevantLabels = ["equalToConstant", "greaterThanOrEqualToConstant"]
        default:
            return
        }

        guard node.arguments.contains(where: { argument in
            guard let label = argument.label?.text,
                  relevantLabels.contains(label) else {
                return false
            }
            return containsNumericLiteral(
                argument.expression,
                equalTo: policy.interactionPolicy.touchTargetLiteral
            )
        }) else {
            return
        }

        let declaration = enclosingDeclarationIdentifier(for: Syntax(node))
        append(
            ruleID: policy.interactionPolicy.touchTargetRuleID,
            node: node,
            message: "交互尺寸不得在 \(baseName) 中直接写 44pt；请使用 InteractionMetrics.minimumTouchTarget，纯视觉尺寸则归入局部 Metrics。",
            reportDisposition: .candidate,
            reportGroup: "touch-target-call|\(baseName)|\(declaration)"
        )
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard declaresStaticTypeMember(node.modifiers),
              let owner = enclosingTypeOwner(for: Syntax(node)) else {
            return .visitChildren
        }
        appendRestrictedDeclarationIfNeeded(
            owner: owner,
            member: node.name.text,
            node: node
        )
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let expression = node.trimmedDescription.replacingOccurrences(of: " ", with: "")
        let disabledBounceAssignments = [
            "alwaysBounceVertical=false",
            "alwaysBounceHorizontal=false",
            ".bounces=false"
        ]
        if disabledBounceAssignments.contains(where: expression.contains) {
            append(
                ruleID: "DS005",
                node: node,
                message: "应用自有 UIKit 滚动容器不得关闭有效轴向回弹。"
            )
        }
        return .visitChildren
    }

    private var isProductionPath: Bool {
        path.hasPrefix("xmnote/") && !path.contains("/Debug/")
    }

    private func isAllowedOwner(for constructionPolicy: ConstructionPolicy) -> Bool {
        constructionPolicy.allowedPaths.contains(path)
    }

    /// 匹配完整成员入口，并仅对 policy 明示的项目专有 helper 接受 Swift 推断式成员写法。
    private func matchingSymbolPolicies(for node: MemberAccessExprSyntax) -> [SymbolPolicy] {
        if node.base != nil {
            let components = node.trimmedDescription.split(separator: ".")
            let normalizedSymbol = components.suffix(2).joined(separator: ".")
            return policy.symbolPolicies.filter { $0.symbols.contains(normalizedSymbol) }
        }

        let member = node.declName.baseName.text
        return policy.symbolPolicies.filter { symbolPolicy in
            symbolPolicy.matchInferred == true
                && symbolPolicy.symbols.contains { $0.hasSuffix(".\(member)") }
        }
    }

    /// 受限入口的定义本身也必须位于登记 owner，避免已删除 token 通过新声明重新出现。
    private func appendRestrictedDeclarationIfNeeded(
        owner: String,
        member: String,
        node: some SyntaxProtocol
    ) {
        let symbol = "\(owner).\(member)"
        guard let symbolPolicy = policy.symbolPolicies.first(where: { $0.symbols.contains(symbol) }),
              !symbolPolicy.allowedPaths.contains(path) else {
            return
        }
        append(
            ruleID: symbolPolicy.ruleID,
            node: node,
            message: "不得在未登记 owner 中声明 \(symbol)；请改用 \(symbolPolicy.replacement)。"
        )
    }

    /// 只把真正的 static/class 类型成员拼成受限 symbol；局部变量与嵌套函数不参与判断。
    private func declaresStaticTypeMember(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            modifier.name.text == "static" || modifier.name.text == "class"
        }
    }

    /// 返回最近的类型或 extension owner，并把 `SwiftUI.Color` 规范化为 policy 使用的 `Color`。
    private func enclosingTypeOwner(for syntax: Syntax) -> String? {
        var ancestor = syntax.parent
        while let current = ancestor {
            if current.as(FunctionDeclSyntax.self) != nil
                || current.as(InitializerDeclSyntax.self) != nil
                || current.as(DeinitializerDeclSyntax.self) != nil
                || current.as(AccessorDeclSyntax.self) != nil
                || current.as(ClosureExprSyntax.self) != nil {
                return nil
            }
            if let declaration = current.as(ExtensionDeclSyntax.self) {
                return normalizedTypeOwner(declaration.extendedType.trimmedDescription)
            }
            if let declaration = current.as(StructDeclSyntax.self) {
                return declaration.name.text
            }
            if let declaration = current.as(ClassDeclSyntax.self) {
                return declaration.name.text
            }
            if let declaration = current.as(EnumDeclSyntax.self) {
                return declaration.name.text
            }
            if let declaration = current.as(ActorDeclSyntax.self) {
                return declaration.name.text
            }
            ancestor = current.parent
        }
        return nil
    }

    private func normalizedTypeOwner(_ type: String) -> String {
        type.split(separator: ".").last.map(String.init) ?? type
    }

    /// `Image.font` sizes an SF Symbol glyph rather than production text, so it follows icon semantics.
    private func isImageGlyphFontCall(_ node: FunctionCallExprSyntax) -> Bool {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.text == "font",
              let receiver = memberAccess.base else {
            return false
        }
        return rootFunctionName(in: receiver) == "Image"
    }

    /// Follows a modifier chain without descending into call arguments, so nested Image values do not exempt Text.
    private func rootFunctionName(in expression: ExprSyntax) -> String? {
        if let functionCall = expression.as(FunctionCallExprSyntax.self) {
            if let reference = functionCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text
            }
            if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
                if memberAccess.declName.baseName.text == "Image" {
                    return "Image"
                }
                guard let base = memberAccess.base else { return nil }
                return rootFunctionName(in: base)
            }
            return nil
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self),
           let base = memberAccess.base {
            return rootFunctionName(in: base)
        }
        return nil
    }

    private func append(
        ruleID: String,
        node: some SyntaxProtocol,
        message: String,
        reportDisposition: ReportDisposition? = nil,
        reportGroup: String? = nil
    ) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let evidence = node.trimmedDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        diagnostics.append(
            LintDiagnostic(
                ruleID: ruleID,
                path: path,
                line: location.line,
                column: location.column,
                declaration: enclosingDeclaration(for: Syntax(node)),
                evidence: String(evidence.prefix(240)),
                message: message,
                reportDisposition: reportDisposition,
                reportGroup: reportGroup
            )
        )
    }

    private func enclosingDeclaration(for syntax: Syntax) -> String {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let function = current.as(FunctionDeclSyntax.self) {
                return "func \(function.name.text)"
            }
            if current.as(InitializerDeclSyntax.self) != nil {
                return "init"
            }
            if let variable = current.as(VariableDeclSyntax.self),
               let binding = variable.bindings.first {
                return "var \(binding.pattern.trimmedDescription)"
            }
            if let structure = current.as(StructDeclSyntax.self) {
                return "struct \(structure.name.text)"
            }
            if let classDeclaration = current.as(ClassDeclSyntax.self) {
                return "class \(classDeclaration.name.text)"
            }
            if let enumeration = current.as(EnumDeclSyntax.self) {
                return "enum \(enumeration.name.text)"
            }
            if let extensionDeclaration = current.as(ExtensionDeclSyntax.self) {
                return "extension \(extensionDeclaration.extendedType.trimmedDescription)"
            }
            ancestor = current.parent
        }
        return "file"
    }

    private func enclosingDeclarationIdentifier(for syntax: Syntax) -> String {
        var member: String?
        var owner: String?
        var ancestor = syntax.parent
        while let current = ancestor {
            if member == nil, let function = current.as(FunctionDeclSyntax.self) {
                member = function.name.text
            } else if member == nil,
                      let variable = current.as(VariableDeclSyntax.self),
                      let binding = variable.bindings.first,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                member = identifier.identifier.text
            }
            if owner == nil, let type = typeName(of: current) {
                owner = type
            }
            if member != nil, owner != nil { break }
            ancestor = current.parent
        }
        switch (owner, member) {
        case let (.some(owner), .some(member)):
            return "\(owner).\(member)"
        case let (.some(owner), .none):
            return owner
        case let (.none, .some(member)):
            return member
        case (.none, .none):
            return "file"
        }
    }

    private func containsNumericLiteral(_ syntax: some SyntaxProtocol) -> Bool {
        syntax.tokens(viewMode: .sourceAccurate).contains { token in
            switch token.tokenKind {
            case .integerLiteral, .floatLiteral:
                return true
            default:
                return false
            }
        }
    }

    private func containsNumericLiteral(
        _ syntax: some SyntaxProtocol,
        equalTo expectedValue: Double
    ) -> Bool {
        syntax.tokens(viewMode: .sourceAccurate).contains { token in
            let literal: String
            switch token.tokenKind {
            case .integerLiteral(let value), .floatLiteral(let value):
                literal = value
            default:
                return false
            }
            return Double(literal.replacingOccurrences(of: "_", with: "")) == expectedValue
        }
    }

    private func directNumericLiteralValue(_ syntax: some SyntaxProtocol) -> Double? {
        let tokens = Array(syntax.tokens(viewMode: .sourceAccurate))
        guard tokens.count == 1 else { return nil }
        let literal: String
        switch tokens[0].tokenKind {
        case .integerLiteral(let value), .floatLiteral(let value):
            literal = value
        default:
            return nil
        }
        return Double(literal.replacingOccurrences(of: "_", with: ""))
    }

    /// Finds layout literals while ignoring numbers owned by nested calculations such as row indexes.
    private func containsDirectNumericLiteral(_ syntax: some SyntaxProtocol) -> Bool {
        let visitor = DirectNumericLiteralVisitor()
        visitor.walk(Syntax(syntax))
        return visitor.hasNumericLiteral
    }

    private func containsNumericCornerLiteral(_ node: FunctionCallExprSyntax) -> Bool {
        if let cornerArgument = node.arguments.first(where: { $0.label?.text == "cornerRadius" }) {
            return containsNumericLiteral(cornerArgument.expression)
        }
        return node.calledExpression.trimmedDescription.hasSuffix(".cornerRadius")
            && containsNumericLiteral(node.arguments)
    }

    private func literalSystemImageName(_ node: FunctionCallExprSyntax) -> String? {
        for argument in node.arguments {
            guard argument.label?.text == "systemName" || argument.label?.text == "systemImage" else {
                continue
            }
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  literal.segments.count == 1,
                  case .stringSegment(let segment)? = literal.segments.first else {
                continue
            }
            return segment.content.text
        }
        return nil
    }

    private func containsDurationLiteral(_ node: FunctionCallExprSyntax) -> Bool {
        guard let durationArgument = node.arguments.first(where: {
            $0.label?.text == "duration" || $0.label?.text == "response"
        }) else {
            return false
        }
        return containsNumericLiteral(durationArgument.expression)
    }

    private var reportModule: String {
        let components = path.split(separator: "/").map(String.init)
        guard components.first == "xmnote", components.count > 1 else { return "repository" }
        if components.count > 2, components[1] == "Views" || components[1] == "UIComponents" {
            return "\(components[1])/\(components[2])"
        }
        return components[1]
    }

    private func motionReportClassification(
        for node: FunctionCallExprSyntax
    ) -> (disposition: ReportDisposition, group: String) {
        if let owner = nearestEnclosingTypeName(for: Syntax(node)), isSemanticMotionOwner(owner) {
            return (.inventory, "motion|semantic-owner|\(owner)")
        }
        if let property = namedMotionProperty(for: Syntax(node)) {
            return (.inventory, "motion|named-property|\(property)")
        }
        if hasReduceMotionBranch(around: Syntax(node)) {
            return (.inventory, "motion|reduce-motion-branch")
        }
        return (.candidate, "motion|inline-literal")
    }

    private func isSemanticMotionOwner(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "loadingpolicy"
            || normalized.hasSuffix("motion")
            || normalized.hasSuffix("motionspec")
            || normalized.hasSuffix("animationspec")
            || normalized.hasSuffix("transitionspec")
    }

    private func namedMotionProperty(for syntax: Syntax) -> String? {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let declaration = current.as(VariableDeclSyntax.self) {
                guard isTypeMember(declaration) else { return nil }
                for binding in declaration.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    let name = identifier.identifier.text
                    let normalizedName = name.lowercased()
                    let type = binding.typeAnnotation?.type.trimmedDescription.lowercased() ?? ""
                    if normalizedName.contains("animation")
                        || normalizedName.contains("transition")
                        || normalizedName.contains("motion")
                        || type.contains("animation")
                        || type.contains("transition") {
                        return name
                    }
                }
                return nil
            }
            if current.as(FunctionDeclSyntax.self) != nil
                || current.as(InitializerDeclSyntax.self) != nil
                || current.as(ClosureExprSyntax.self) != nil {
                return nil
            }
            ancestor = current.parent
        }
        return nil
    }

    private func isTypeMember(_ declaration: VariableDeclSyntax) -> Bool {
        var ancestor = Syntax(declaration).parent
        while let current = ancestor {
            if current.as(FunctionDeclSyntax.self) != nil
                || current.as(InitializerDeclSyntax.self) != nil
                || current.as(ClosureExprSyntax.self) != nil {
                return false
            }
            if current.as(StructDeclSyntax.self) != nil
                || current.as(ClassDeclSyntax.self) != nil
                || current.as(EnumDeclSyntax.self) != nil
                || current.as(ActorDeclSyntax.self) != nil
                || current.as(ExtensionDeclSyntax.self) != nil {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    private func hasReduceMotionBranch(around syntax: Syntax) -> Bool {
        var ancestor: Syntax? = syntax
        while let current = ancestor {
            let hasConditionalSyntax = current.as(TernaryExprSyntax.self) != nil
                || current.as(IfExprSyntax.self) != nil
                || current.tokens(viewMode: .sourceAccurate).contains { $0.text == "?" }
            if hasConditionalSyntax, containsReduceMotionIdentifier(current) {
                return true
            }
            if current.as(FunctionDeclSyntax.self) != nil
                || current.as(InitializerDeclSyntax.self) != nil
                || current.as(VariableDeclSyntax.self) != nil {
                return false
            }
            ancestor = current.parent
        }
        return false
    }

    private func containsReduceMotionIdentifier(_ syntax: Syntax) -> Bool {
        syntax.tokens(viewMode: .sourceAccurate).contains { token in
            guard case .identifier(let name) = token.tokenKind else { return false }
            return name.lowercased().contains("reducemotion")
        }
    }

    private func progressReportClassification(
        for node: FunctionCallExprSyntax
    ) -> (disposition: ReportDisposition, group: String) {
        if node.arguments.contains(where: {
            $0.label?.text == "value" || $0.label?.text == "timerInterval"
        }) {
            return (.inventory, "progress|determinate")
        }
        if isDesignSystemLoadingOwner(for: Syntax(node)) {
            return (.inventory, "progress|design-system-loading")
        }
        if isInsideInteractiveFeedback(Syntax(node)) {
            return (.inventory, "progress|interactive-operation")
        }
        if let owner = namedProgressOwner(for: Syntax(node)) {
            return (.inventory, "progress|named-owner|\(owner)")
        }
        if hasProgressStateCondition(around: Syntax(node)) {
            return (.inventory, "progress|operation-state")
        }
        return (.candidate, "progress|unclassified")
    }

    private func isDesignSystemLoadingOwner(for syntax: Syntax) -> Bool {
        guard path.hasPrefix("xmnote/UIComponents/") else { return false }
        guard let owner = nearestEnclosingTypeName(for: syntax) else { return false }
        let normalized = owner.lowercased()
        return normalized.contains("loadingstate") || normalized.contains("loadphase")
    }

    private func isInsideInteractiveFeedback(_ syntax: Syntax) -> Bool {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let call = current.as(FunctionCallExprSyntax.self) {
                let callee = call.calledExpression.trimmedDescription
                let baseName = callee.split(separator: ".").last.map(String.init) ?? callee
                if baseName == "Button" || baseName == "Menu" {
                    return true
                }
            }
            if current.as(FunctionDeclSyntax.self) != nil { return false }
            ancestor = current.parent
        }
        return false
    }

    private func namedProgressOwner(for syntax: Syntax) -> String? {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let function = current.as(FunctionDeclSyntax.self),
               isProgressOwnerName(function.name.text) {
                return function.name.text
            }
            if let variable = current.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                       isProgressOwnerName(identifier.identifier.text) {
                        return identifier.identifier.text
                    }
                }
            }
            if let owner = typeName(of: current), isProgressOwnerName(owner) {
                return owner
            }
            ancestor = current.parent
        }
        return nil
    }

    private func isProgressOwnerName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return Self.progressOwnerTerms.contains(where: normalized.contains)
    }

    private func hasProgressStateCondition(around syntax: Syntax) -> Bool {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let expression = current.as(IfExprSyntax.self) {
                let condition = expression.conditions.trimmedDescription.lowercased()
                if Self.progressOwnerTerms.contains(where: condition.contains) {
                    return true
                }
            }
            let hasConditionalState = current.tokens(viewMode: .sourceAccurate).contains {
                $0.text == "?"
            }
            if hasConditionalState {
                let expression = current.trimmedDescription.lowercased()
                if Self.progressOwnerTerms.contains(where: expression.contains) {
                    return true
                }
            }
            if current.as(FunctionDeclSyntax.self) != nil
                || current.as(VariableDeclSyntax.self) != nil {
                return false
            }
            ancestor = current.parent
        }
        return false
    }

    private func nearestEnclosingTypeName(for syntax: Syntax) -> String? {
        var ancestor = syntax.parent
        while let current = ancestor {
            if let name = typeName(of: current) {
                return name
            }
            ancestor = current.parent
        }
        return nil
    }

    private func typeName(of syntax: Syntax) -> String? {
        if let declaration = syntax.as(StructDeclSyntax.self) {
            return declaration.name.text
        }
        if let declaration = syntax.as(ClassDeclSyntax.self) {
            return declaration.name.text
        }
        if let declaration = syntax.as(EnumDeclSyntax.self) {
            return declaration.name.text
        }
        if let declaration = syntax.as(ActorDeclSyntax.self) {
            return declaration.name.text
        }
        if let declaration = syntax.as(ExtensionDeclSyntax.self) {
            return normalizedTypeOwner(declaration.extendedType.trimmedDescription)
        }
        return nil
    }

    private static let stackConstructors: Set<String> = [
        "HStack", "VStack", "LazyHStack", "LazyVStack"
    ]

    private static let cornerConstructors: Set<String> = [
        "RoundedRectangle", "rect", "cornerRadius"
    ]

    private static let animationConstructors: Set<String> = [
        "animation", "smooth", "snappy", "spring", "easeIn", "easeOut", "easeInOut", "linear"
    ]

    private static let progressOwnerTerms = [
        "loading", "processing", "progress", "saving", "upload", "import",
        "export", "restor", "captur", "backup", "revok", "prepar", "complet"
    ]
}

private final class DirectNumericLiteralVisitor: SyntaxVisitor {
    private(set) var hasNumericLiteral = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        hasNumericLiteral = true
        return .skipChildren
    }

    override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        hasNumericLiteral = true
        return .skipChildren
    }
}
