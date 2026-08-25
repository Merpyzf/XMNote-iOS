import Foundation
import SwiftParser
import SwiftSyntax

public struct LintDiagnostic: Codable, Equatable, Sendable {
    public let ruleID: String
    public let path: String
    public let line: Int
    public let column: Int
    public let declaration: String
    public let evidence: String
    public let message: String

    public init(
        ruleID: String,
        path: String,
        line: Int,
        column: Int,
        declaration: String,
        evidence: String,
        message: String
    ) {
        self.ruleID = ruleID
        self.path = path
        self.line = line
        self.column = column
        self.declaration = declaration
        self.evidence = evidence
        self.message = message
    }
}

/// Parses production Swift source and emits design-system diagnostics anchored to syntax nodes.
public struct RuleEngine: Sendable {
    public init() {}

    /// Lints one source file without reading global state, so callers can batch or test deterministically.
    public func lint(source: String, path: String) -> [LintDiagnostic] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = DesignRuleVisitor(path: path, converter: converter)
        visitor.walk(tree)
        return visitor.diagnostics.sorted {
            ($0.line, $0.column, $0.ruleID) < ($1.line, $1.column, $1.ruleID)
        }
    }
}

private final class DesignRuleVisitor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var diagnostics: [LintDiagnostic] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
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

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        let baseName = callee.split(separator: ".").last.map(String.init) ?? callee
        let arguments = node.arguments.trimmedDescription

        let constructsSwiftUIFont = baseName == "font" && arguments.contains(".system(")
        let constructsUIKitFont = callee.hasSuffix("UIFont.systemFont")
            || callee.hasSuffix("UIFont.boldSystemFont")
        if !isTypographyDefinitionPath,
           (constructsUIKitFont || (constructsSwiftUIFont && !isImageGlyphFontCall(node))) {
            append(
                ruleID: "DS001",
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
           !node.arguments.isEmpty,
           !isColorDefinitionPath {
            append(
                ruleID: "DS003",
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

        if (baseName == "Image" || baseName == "Label"), hasLiteralSystemImageArgument(node) {
            append(
                ruleID: "DSR001",
                node: node,
                message: "字面量 SF Symbol 尚未形成强约束；请确认语义、尺寸和组件 owner。"
            )
        }

        if Self.animationConstructors.contains(baseName), containsDurationLiteral(node) {
            append(
                ruleID: "DSR002",
                node: node,
                message: "动画时长为字面量；请确认它属于局部运动语义而非重复魔法数字。"
            )
        }

        if baseName == "ProgressView", isProductionPath {
            append(
                ruleID: "DSR003",
                node: node,
                message: "发现裸 ProgressView；读取主态应优先使用项目加载反馈组件。"
            )
        }

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

    private var isColorDefinitionPath: Bool {
        path == "xmnote/Utilities/DesignSystem/SemanticColors.swift"
            || path == "xmnote/Utilities/DesignSystem/ColorConstruction.swift"
    }

    private var isTypographyDefinitionPath: Bool {
        Self.typographyDefinitionPaths.contains(path)
    }

    /// `Image.font` sizes an SF Symbol glyph rather than production text, so it follows icon semantics.
    private func isImageGlyphFontCall(_ node: FunctionCallExprSyntax) -> Bool {
        node.calledExpression.trimmedDescription.contains("Image(")
    }

    private func append(ruleID: String, node: some SyntaxProtocol, message: String) {
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
                message: message
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

    private func hasLiteralSystemImageArgument(_ node: FunctionCallExprSyntax) -> Bool {
        node.arguments.contains { argument in
            guard argument.label?.text == "systemName" || argument.label?.text == "systemImage" else {
                return false
            }
            return argument.expression.as(StringLiteralExprSyntax.self) != nil
        }
    }

    private func containsDurationLiteral(_ node: FunctionCallExprSyntax) -> Bool {
        guard let durationArgument = node.arguments.first(where: {
            $0.label?.text == "duration" || $0.label?.text == "response"
        }) else {
            return false
        }
        return containsNumericLiteral(durationArgument.expression)
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

    private static let typographyDefinitionPaths: Set<String> = [
        "xmnote/Utilities/DesignSystem/AppTypography.swift",
        "xmnote/Utilities/DesignSystem/SharedContentTypography.swift",
        "xmnote/Utilities/SemanticTypography.swift",
        "xmnote/Utilities/BrandTypography.swift"
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
