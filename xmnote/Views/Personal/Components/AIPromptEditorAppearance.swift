/**
 * [INPUT]: 依赖 SwiftUI/UIKit、AppTypography 与集中式颜色构造器，接收受控提示词变量定义和当前 trait
 * [OUTPUT]: 对内提供 AI Prompt 编辑器的自适应 Tonal 调色板、Reicon 资产映射、排版与局部几何
 * [POS]: Views/Personal/Components 的 feature-private 外观 owner，被变量工具栏与 TextKit 原子令牌共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// Prompt 编辑器内部的动态 Tonal 色，确保 SwiftUI 与 UIKit 在相同 trait 下得到同一色值。
fileprivate struct AIPromptEditorTonalColor {
    let lightHex: UInt
    let darkHex: UInt
    let highContrastLightHex: UInt
    let highContrastDarkHex: UInt

    /// 供 SwiftUI 组件使用、随外观与对比度变化的颜色。
    var color: Color {
        Color.xmAdaptive(
            light: Color.xmHex(lightHex),
            dark: Color.xmHex(darkHex),
            highContrastLight: Color.xmHex(highContrastLightHex),
            highContrastDark: Color.xmHex(highContrastDarkHex)
        )
    }

    /// 供 TextKit 附件使用、随外观与对比度变化的 UIKit 颜色。
    var uiColor: UIColor {
        UIColor.xmAdaptive(
            lightHex: lightHex,
            darkHex: darkHex,
            highContrastLightHex: highContrastLightHex,
            highContrastDarkHex: highContrastDarkHex
        )
    }
}

/// 单个变量在 Prompt 编辑器中的视觉映射；业务模型不持有任何 UI 类型或资产名称。
struct AIPromptVariablePresentation {
    let iconAssetName: String
    private let background: AIPromptEditorTonalColor
    private let emphasizedBackground: AIPromptEditorTonalColor
    private let foreground: AIPromptEditorTonalColor

    fileprivate init(
        iconAssetName: String,
        background: AIPromptEditorTonalColor,
        emphasizedBackground: AIPromptEditorTonalColor,
        foreground: AIPromptEditorTonalColor
    ) {
        self.iconAssetName = iconAssetName
        self.background = background
        self.emphasizedBackground = emphasizedBackground
        self.foreground = foreground
    }

    var backgroundColor: Color { background.color }
    var emphasizedBackgroundColor: Color { emphasizedBackground.color }
    var uiBackgroundColor: UIColor { background.uiColor }
    var uiEmphasizedBackgroundColor: UIColor { emphasizedBackground.uiColor }
    var foregroundColor: Color { foreground.color }
    var uiForegroundColor: UIColor { foreground.uiColor }
}

/// Prompt 编辑器的局部外观入口，确保 SwiftUI Chip 与 UIKit 附件使用同一组视觉参数。
enum AIPromptEditorAppearance {
    enum Metrics {
        static let editorLineSpacing: CGFloat = 3
        static let editorParagraphSpacing: CGFloat = 5

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

    /// 系统撤销图标，沿用平台编辑语义并由 SwiftUI 负责字重与禁用态。
    static let undoSystemImageName = "arrow.uturn.backward"

    /// 系统重做图标，沿用平台编辑语义并由 SwiftUI 负责字重与禁用态。
    static let redoSystemImageName = "arrow.uturn.forward"

    /// 按变量语义映射 Reicon Filled 资产与浅深模式均可读的 Tonal 色；颜色不承担必需或已插入状态。
    static func presentation(
        for variable: AIPromptVariableDefinition
    ) -> AIPromptVariablePresentation {
        let palette = palette(for: variable.category)
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

    /// 返回类别在浅色、深色、按压和提高对比度环境下共用的三角色颜色。
    private static func palette(
        for category: AIPromptVariableCategory
    ) -> (
        background: AIPromptEditorTonalColor,
        emphasizedBackground: AIPromptEditorTonalColor,
        foreground: AIPromptEditorTonalColor
    ) {
        switch category {
        case .content:
            (
                AIPromptEditorTonalColor(
                    lightHex: 0xF3AE9A,
                    darkHex: 0x9C4933,
                    highContrastLightHex: 0xF3AE9A,
                    highContrastDarkHex: 0x873D2B
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0xE9997F,
                    darkHex: 0x873D2B,
                    highContrastLightHex: 0xE9997F,
                    highContrastDarkHex: 0x6E2F21
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0x6B2B18,
                    darkHex: 0xFFF3EF,
                    highContrastLightHex: 0x461608,
                    highContrastDarkHex: 0xFFFFFF
                )
            )
        case .context:
            (
                AIPromptEditorTonalColor(
                    lightHex: 0x8AD4DF,
                    darkHex: 0x167888,
                    highContrastLightHex: 0x8AD4DF,
                    highContrastDarkHex: 0x126A79
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0x72C6D2,
                    darkHex: 0x126A79,
                    highContrastLightHex: 0x72C6D2,
                    highContrastDarkHex: 0x0B5260
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0x004B55,
                    darkHex: 0xF2FCFF,
                    highContrastLightHex: 0x00343C,
                    highContrastDarkHex: 0xFFFFFF
                )
            )
        case .metadata:
            (
                AIPromptEditorTonalColor(
                    lightHex: 0x8BBEF0,
                    darkHex: 0x286EA6,
                    highContrastLightHex: 0x8BBEF0,
                    highContrastDarkHex: 0x225F91
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0x72ACE0,
                    darkHex: 0x225F91,
                    highContrastLightHex: 0x72ACE0,
                    highContrastDarkHex: 0x194B74
                ),
                AIPromptEditorTonalColor(
                    lightHex: 0x0B3F75,
                    darkHex: 0xF3F9FF,
                    highContrastLightHex: 0x062953,
                    highContrastDarkHex: 0xFFFFFF
                )
            )
        }
    }
}
