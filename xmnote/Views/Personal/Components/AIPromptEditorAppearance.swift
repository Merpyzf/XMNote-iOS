/**
 * [INPUT]: 依赖 SwiftUI/UIKit、AppTypography 与系统动态语义色，接收受控提示词变量定义和当前 trait
 * [OUTPUT]: 对内提供 AI Prompt 编辑器的原生动态配色、Reicon 资产映射、排版与局部几何
 * [POS]: Views/Personal/Components 的 feature-private 外观 owner，被变量工具栏与 TextKit 原子令牌共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// Prompt 编辑器内部的系统动态色桥接，确保 SwiftUI 与 UIKit 使用同一语义色和透明度。
fileprivate struct AIPromptEditorSystemColor {
    let color: Color
    let uiColor: UIColor

    init(_ uiColor: UIColor, opacity: Double = 1) {
        let color = Color.xmResolved(uiColor).opacity(opacity)
        self.color = color
        self.uiColor = UIColor.xmResolved(color)
    }
}

/// 单个变量在 Prompt 编辑器中的视觉映射；业务模型不持有任何 UI 类型或资产名称。
struct AIPromptVariablePresentation {
    let iconAssetName: String
    private let background: AIPromptEditorSystemColor
    private let emphasizedBackground: AIPromptEditorSystemColor
    private let foreground: AIPromptEditorSystemColor

    fileprivate init(
        iconAssetName: String,
        background: AIPromptEditorSystemColor,
        emphasizedBackground: AIPromptEditorSystemColor,
        foreground: AIPromptEditorSystemColor
    ) {
        self.iconAssetName = iconAssetName
        self.background = background
        self.emphasizedBackground = emphasizedBackground
        self.foreground = foreground
    }

    var backgroundColor: Color { background.color }
    var emphasizedBackgroundColor: Color { emphasizedBackground.color }
    var uiBackgroundColor: UIColor { background.uiColor }
    var foregroundColor: Color { foreground.color }
    var uiForegroundColor: UIColor { foreground.uiColor }
}

/// Prompt 编辑器的局部外观入口，确保 SwiftUI Chip 与 UIKit 附件使用同一组视觉参数。
enum AIPromptEditorAppearance {
    private static let defaultTintOpacity = 0.12
    private static let pressedTintOpacity = 0.18

    enum Metrics {
        static let editorLineSpacing: CGFloat = 3
        static let editorParagraphSpacing: CGFloat = 5
        static let diffLineSpacing: CGFloat = 5
        static let diffParagraphSpacing: CGFloat = 8

        static let chipHeight: CGFloat = 28
        static let chipCornerRadius: CGFloat = chipHeight / 2
        static let chipHorizontalPadding: CGFloat = 12
        static let chipIconSpacing: CGFloat = 5
        static let chipIconSize: CGFloat = 13

        static let tokenMinimumHeight: CGFloat = 22
        static let tokenCornerRadius: CGFloat = tokenMinimumHeight / 2
        static let tokenHorizontalPadding: CGFloat = 7
        static let tokenIconSpacing: CGFloat = 4
        static let tokenIconBaseSize: CGFloat = 11

        static let barHeight: CGFloat = 44
        static let commandBarWidth: CGFloat = 88
        static let groupSpacing: CGFloat = 8
        static let commandIconSize: CGFloat = 17
    }

    static var chipFont: Font {
        AppTypography.fixed(
            baseSize: 12,
            relativeTo: .caption,
            weight: .medium,
            minimumPointSize: 12
        )
    }

    static var editorBodyFont: Font { AppTypography.body }

    /// 返回当前 Dynamic Type 环境下的正文 UIKit 字体，供 TextKit 渲染和测量共同使用。
    static func uiEditorBodyFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        AppTypography.uiFixed(
            baseSize: 17,
            textStyle: .body,
            minimumPointSize: 17,
            compatibleWith: traits
        )
    }

    /// 返回当前 Dynamic Type 环境下的差异正文字体，以 15pt subheadline 层级保持长文本阅读密度。
    static func uiDiffBodyFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        AppTypography.uiFixed(
            baseSize: 15,
            textStyle: .subheadline,
            minimumPointSize: 15,
            compatibleWith: traits
        )
    }

    /// 返回当前 Dynamic Type 环境下的令牌 UIKit 字体，默认保持 12pt 的紧凑密度。
    static func uiTokenFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        AppTypography.uiFixed(
            baseSize: 12,
            textStyle: .caption1,
            weight: .medium,
            minimumPointSize: 12,
            compatibleWith: traits
        )
    }

    /// 返回正文基础属性；行距、段距、字体与正文色只由该 feature owner 维护。
    static func editorBaseAttributes(
        compatibleWith traits: UITraitCollection?
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Metrics.editorLineSpacing
        paragraphStyle.paragraphSpacing = Metrics.editorParagraphSpacing
        return [
            .font: uiEditorBodyFont(compatibleWith: traits),
            .foregroundColor: UIColor.xmResolved(Color.textPrimary),
            .paragraphStyle: paragraphStyle,
        ]
    }

    /// 返回只读差异正文基础属性；字体、行距、段距与新增正文色由该 feature owner 统一维护。
    static func diffBaseAttributes(
        compatibleWith traits: UITraitCollection?
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Metrics.diffLineSpacing
        paragraphStyle.paragraphSpacing = Metrics.diffParagraphSpacing
        return [
            .font: uiDiffBodyFont(compatibleWith: traits),
            .foregroundColor: UIColor.xmResolved(Color.textPrimary),
            .paragraphStyle: paragraphStyle,
        ]
    }

    /// 系统撤销图标，沿用平台编辑语义并由 SwiftUI 负责字重与禁用态。
    static let undoSystemImageName = "arrow.uturn.backward"

    /// 系统重做图标，沿用平台编辑语义并由 SwiftUI 负责字重与禁用态。
    static let redoSystemImageName = "arrow.uturn.forward"

    /// 按变量语义映射 Reicon Filled 资产与系统动态色；颜色不承担必需或已插入状态。
    static func presentation(
        for variable: AIPromptVariableDefinition
    ) -> AIPromptVariablePresentation {
        let palette = palette(for: variable.name)
        return AIPromptVariablePresentation(
            iconAssetName: iconAssetName(for: variable.name),
            background: palette.background,
            emphasizedBackground: palette.emphasizedBackground,
            foreground: palette.foreground
        )
    }

    /// 将受支持的变量名称映射到随功能打包的 Reicon Filled 模板资产。
    private static func iconAssetName(for variableName: String) -> String {
        switch variableName {
        case "摘录", "书摘内容":
            "AIPromptReiconQuoteUp"
        case "想法":
            "AIPromptReiconBulb2"
        case "章节":
            "AIPromptReiconList3"
        case "书籍名":
            "AIPromptReiconBookOpen"
        case "作者名":
            "AIPromptReiconUser"
        case "查询文本":
            "AIPromptReiconSearch"
        case "上下文":
            "AIPromptReiconTextAlignLeft"
        case "已有标签":
            "AIPromptReiconTags"
        default:
            "AIPromptReiconQuoteUp"
        }
    }

    /// 返回变量在默认与按压状态下共用的系统语义色，亮暗和高对比度均交由 UIKit 动态解析。
    private static func palette(
        for variableName: String
    ) -> (
        background: AIPromptEditorSystemColor,
        emphasizedBackground: AIPromptEditorSystemColor,
        foreground: AIPromptEditorSystemColor
    ) {
        switch variableName {
        case "摘录", "书摘内容", "查询文本":
            tintedPalette(baseColor: .systemOrange)
        case "想法", "上下文":
            tintedPalette(baseColor: .systemTeal)
        case "书籍名", "作者名", "章节", "已有标签":
            tintedPalette(baseColor: .systemBlue)
        default:
            neutralPalette()
        }
    }

    /// 以系统色本身作为前景，并用轻量透明度承载默认和按压状态。
    private static func tintedPalette(
        baseColor: UIColor
    ) -> (
        background: AIPromptEditorSystemColor,
        emphasizedBackground: AIPromptEditorSystemColor,
        foreground: AIPromptEditorSystemColor
    ) {
        (
            AIPromptEditorSystemColor(baseColor, opacity: defaultTintOpacity),
            AIPromptEditorSystemColor(baseColor, opacity: pressedTintOpacity),
            AIPromptEditorSystemColor(baseColor)
        )
    }

    /// 中性变量使用系统标签色与 Fill 层级，避免为未知语义派生额外业务色。
    private static func neutralPalette() -> (
        background: AIPromptEditorSystemColor,
        emphasizedBackground: AIPromptEditorSystemColor,
        foreground: AIPromptEditorSystemColor
    ) {
        (
            AIPromptEditorSystemColor(.secondarySystemFill),
            AIPromptEditorSystemColor(.systemFill),
            AIPromptEditorSystemColor(.secondaryLabel)
        )
    }
}
