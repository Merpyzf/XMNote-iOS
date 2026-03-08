#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 UIKit/SwiftUI 系统颜色语义集合，依赖 CardContainer 与 DesignTokens 提供调试页基础排版能力
 * [OUTPUT]: 对外提供 SystemColorsTestView（系统颜色语义测试页）
 * [POS]: Debug 测试页，按语义分组展示 iOS 系统颜色并提供前景/背景/边框/交互四类案例，帮助团队理解系统颜色落地方式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 系统颜色测试页，提供语义分组、搜索与浅深色切换下的案例化预览。
struct SystemColorsTestView: View {

    /// 控制颜色列表显示范围（全量/语义/基础色）。
    enum ColorScope: String, CaseIterable, Identifiable {
        case all = "全部"
        case semantic = "语义色"
        case base = "基础色"

        var id: String { rawValue }
    }

    /// 控制页面预览使用的外观模式。
    enum SchemePreviewMode: String, CaseIterable, Identifiable {
        case system = "跟随系统"
        case light = "浅色"
        case dark = "深色"

        var id: String { rawValue }
    }

    /// 系统颜色分组，按语义职责划分而非视觉外观划分。
    enum SystemColorGroup: String, CaseIterable, Identifiable {
        case textAndLabel
        case backgrounds
        case fills
        case separators
        case accent
        case chromatic
        case neutrals
        case basics

        var id: String { rawValue }

        /// 当前分组是否归类为“基础色”范围。
        var isBaseGroup: Bool {
            switch self {
            case .chromatic, .neutrals, .basics:
                return true
            case .textAndLabel, .backgrounds, .fills, .separators, .accent:
                return false
            }
        }

        /// 分组标题用于测试页 section 展示。
        var title: String {
            switch self {
            case .textAndLabel:
                return "Text & Label"
            case .backgrounds:
                return "Background"
            case .fills:
                return "Fill"
            case .separators:
                return "Separator"
            case .accent:
                return "Tint & Accent"
            case .chromatic:
                return "System Colors"
            case .neutrals:
                return "System Grays"
            case .basics:
                return "Basic Colors"
            }
        }

        /// 分组说明用于帮助理解该组颜色的业务使用场景。
        var subtitle: String {
            switch self {
            case .textAndLabel:
                return "用于标题、正文、说明和链接等前景语义。"
            case .backgrounds:
                return "用于页面、卡片、分组容器的背景层级。"
            case .fills:
                return "用于控件填充与强调层，常见于胶囊/按钮内衬。"
            case .separators:
                return "用于列表分隔与边框层次。"
            case .accent:
                return "用于交互强调与全局 tint。"
            case .chromatic:
                return "用于状态、类别和品牌之外的系统标准色。"
            case .neutrals:
                return "用于中性色阶与层级灰度控制。"
            case .basics:
                return "静态基础色，不随系统主题自动变化。"
            }
        }
    }

    /// 定义系统颜色条目与语义用途说明。
    struct SystemColorSpec: Identifiable {
        let id: String
        let name: String
        let group: SystemColorGroup
        let usage: String
        let provider: () -> UIColor

        /// 解析当前预览模式下的 RGBA 十六进制，便于核对动态颜色结果。
        func resolvedRGBAHex(for traits: UITraitCollection) -> String {
            let resolved = provider().resolvedColor(with: traits)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                let r = Int(round(red * 255))
                let g = Int(round(green * 255))
                let b = Int(round(blue * 255))
                let a = Int(round(alpha * 255))
                return String(format: "#%02X%02X%02X%02X", r, g, b, a)
            }
            return "无法解析"
        }
    }

    @Environment(\.colorScheme) private var systemColorScheme
    @State private var searchText = ""
    @State private var selectedScope: ColorScope = .all
    @State private var previewMode: SchemePreviewMode = .system

    private static let specs: [SystemColorSpec] = {
        var values: [SystemColorSpec] = [
            .init(id: "label", name: "label", group: .textAndLabel, usage: "默认主文本") { .label },
            .init(id: "secondaryLabel", name: "secondaryLabel", group: .textAndLabel, usage: "次级说明文本") { .secondaryLabel },
            .init(id: "tertiaryLabel", name: "tertiaryLabel", group: .textAndLabel, usage: "弱提示文本") { .tertiaryLabel },
            .init(id: "quaternaryLabel", name: "quaternaryLabel", group: .textAndLabel, usage: "最低层级文本") { .quaternaryLabel },
            .init(id: "placeholderText", name: "placeholderText", group: .textAndLabel, usage: "输入占位提示") { .placeholderText },
            .init(id: "link", name: "link", group: .textAndLabel, usage: "链接语义文本") { .link },

            .init(id: "systemBackground", name: "systemBackground", group: .backgrounds, usage: "页面基础背景") { .systemBackground },
            .init(id: "secondarySystemBackground", name: "secondarySystemBackground", group: .backgrounds, usage: "二级内容背景") { .secondarySystemBackground },
            .init(id: "tertiarySystemBackground", name: "tertiarySystemBackground", group: .backgrounds, usage: "三级内容背景") { .tertiarySystemBackground },
            .init(id: "systemGroupedBackground", name: "systemGroupedBackground", group: .backgrounds, usage: "分组页面背景") { .systemGroupedBackground },
            .init(id: "secondarySystemGroupedBackground", name: "secondarySystemGroupedBackground", group: .backgrounds, usage: "分组内卡片背景") { .secondarySystemGroupedBackground },
            .init(id: "tertiarySystemGroupedBackground", name: "tertiarySystemGroupedBackground", group: .backgrounds, usage: "分组内次级容器背景") { .tertiarySystemGroupedBackground },

            .init(id: "systemFill", name: "systemFill", group: .fills, usage: "强调填充（最强）") { .systemFill },
            .init(id: "secondarySystemFill", name: "secondarySystemFill", group: .fills, usage: "强调填充（二级）") { .secondarySystemFill },
            .init(id: "tertiarySystemFill", name: "tertiarySystemFill", group: .fills, usage: "强调填充（三级）") { .tertiarySystemFill },
            .init(id: "quaternarySystemFill", name: "quaternarySystemFill", group: .fills, usage: "强调填充（最弱）") { .quaternarySystemFill },

            .init(id: "separator", name: "separator", group: .separators, usage: "标准分隔线") { .separator },
            .init(id: "opaqueSeparator", name: "opaqueSeparator", group: .separators, usage: "不透明分隔线") { .opaqueSeparator },

            .init(id: "tintColor", name: "tintColor", group: .accent, usage: "交互 tint 强调") { .tintColor },

            .init(id: "systemRed", name: "systemRed", group: .chromatic, usage: "系统红") { .systemRed },
            .init(id: "systemOrange", name: "systemOrange", group: .chromatic, usage: "系统橙") { .systemOrange },
            .init(id: "systemYellow", name: "systemYellow", group: .chromatic, usage: "系统黄") { .systemYellow },
            .init(id: "systemGreen", name: "systemGreen", group: .chromatic, usage: "系统绿") { .systemGreen },
            .init(id: "systemTeal", name: "systemTeal", group: .chromatic, usage: "系统青绿") { .systemTeal },
            .init(id: "systemCyan", name: "systemCyan", group: .chromatic, usage: "系统青") { .systemCyan },
            .init(id: "systemBlue", name: "systemBlue", group: .chromatic, usage: "系统蓝") { .systemBlue },
            .init(id: "systemIndigo", name: "systemIndigo", group: .chromatic, usage: "系统靛蓝") { .systemIndigo },
            .init(id: "systemPurple", name: "systemPurple", group: .chromatic, usage: "系统紫") { .systemPurple },
            .init(id: "systemPink", name: "systemPink", group: .chromatic, usage: "系统粉") { .systemPink },
            .init(id: "systemBrown", name: "systemBrown", group: .chromatic, usage: "系统棕") { .systemBrown },

            .init(id: "systemGray", name: "systemGray", group: .neutrals, usage: "中性色主灰") { .systemGray },
            .init(id: "systemGray2", name: "systemGray2", group: .neutrals, usage: "中性色 gray2") { .systemGray2 },
            .init(id: "systemGray3", name: "systemGray3", group: .neutrals, usage: "中性色 gray3") { .systemGray3 },
            .init(id: "systemGray4", name: "systemGray4", group: .neutrals, usage: "中性色 gray4") { .systemGray4 },
            .init(id: "systemGray5", name: "systemGray5", group: .neutrals, usage: "中性色 gray5") { .systemGray5 },
            .init(id: "systemGray6", name: "systemGray6", group: .neutrals, usage: "中性色 gray6") { .systemGray6 },

            .init(id: "black", name: "black", group: .basics, usage: "静态黑色") { .black },
            .init(id: "white", name: "white", group: .basics, usage: "静态白色") { .white },
            .init(id: "clear", name: "clear", group: .basics, usage: "透明色") { .clear }
        ]
        if #available(iOS 15.0, *) {
            values.append(
                .init(id: "systemMint", name: "systemMint", group: .chromatic, usage: "系统薄荷绿") { .systemMint }
            )
        }
        return values
    }()

    private var previewColorScheme: ColorScheme {
        switch previewMode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var previewTraitCollection: UITraitCollection {
        let style: UIUserInterfaceStyle = previewColorScheme == .dark ? .dark : .light
        return UITraitCollection(userInterfaceStyle: style)
    }

    private var visibleGroups: [SystemColorGroup] {
        let groups = Set(filteredSpecs.map(\.group))
        return SystemColorGroup.allCases.filter { groups.contains($0) }
    }

    private var filteredSpecs: [SystemColorSpec] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.specs.filter { spec in
            let passScope: Bool
            switch selectedScope {
            case .all:
                passScope = true
            case .semantic:
                passScope = !spec.group.isBaseGroup
            case .base:
                passScope = spec.group.isBaseGroup
            }
            guard passScope else { return false }
            if keyword.isEmpty { return true }
            return spec.name.lowercased().contains(keyword) || spec.usage.lowercased().contains(keyword)
        }
    }

    /// 构建系统颜色测试页，支持语义筛选与浅深色预览。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                controlPanel
                introSection

                ForEach(visibleGroups) { group in
                    groupSection(group)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.windowBackground)
        .navigationTitle("系统颜色测试")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "按颜色名或用途搜索")
        .environment(\.colorScheme, previewColorScheme)
    }
}

private extension SystemColorsTestView {

    var controlPanel: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("预览控制")
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: Spacing.base) {
                    Picker("显示范围", selection: $selectedScope) {
                        ForEach(ColorScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("外观模式", selection: $previewMode) {
                        ForEach(SchemePreviewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(Spacing.base)
        }
    }

    var introSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("使用建议")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("优先使用语义色（如 label / systemBackground / separator），避免在业务代码中硬编码 hex。每个颜色都提供 4 类案例：前景、背景、边框、交互。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.base)
        }
    }

    func groupSection(_ group: SystemColorGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(group.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(group.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: Spacing.base) {
                ForEach(filteredSpecs.filter { $0.group == group }) { spec in
                    SystemColorSpecCard(spec: spec, traitCollection: previewTraitCollection)
                }
            }
        }
        .padding(.top, Spacing.half)
    }
}

/// 系统颜色案例卡片，统一展示单个颜色的语义与四类落地示例。
private struct SystemColorSpecCard: View {
    let spec: SystemColorsTestView.SystemColorSpec
    let traitCollection: UITraitCollection

    private var color: Color { Color(uiColor: spec.provider()) }
    private var resolvedHex: String { spec.resolvedRGBAHex(for: traitCollection) }

    /// 渲染单个系统颜色的样例卡片。
    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                header
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Spacing.half),
                        GridItem(.flexible(), spacing: Spacing.half)
                    ],
                    spacing: Spacing.half
                ) {
                    foregroundCase
                    backgroundCase
                    borderCase
                    controlCase
                }
            }
            .padding(Spacing.base)
        }
    }
}

private extension SystemColorSpecCard {

    var header: some View {
        HStack(spacing: Spacing.base) {
            colorSwatch
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(resolvedHex) · \(spec.usage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    var colorSwatch: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground))
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(color)
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.6)
        }
        .frame(width: 36, height: 36)
    }

    var foregroundCase: some View {
        caseCell(title: "前景文本") {
            VStack(alignment: .leading, spacing: 3) {
                Text("语义文本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text("用于标题/图标")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var backgroundCase: some View {
        caseCell(title: "背景容器") {
            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                .fill(color)
                .frame(height: 30)
                .overlay {
                    Text("Container")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(readableForegroundColor())
                }
        }
    }

    var borderCase: some View {
        caseCell(title: "边框/分隔") {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(color, lineWidth: 1)
                    .frame(height: 16)
                Rectangle()
                    .fill(color)
                    .frame(height: 1)
            }
        }
    }

    var controlCase: some View {
        caseCell(title: "交互控件") {
            HStack(spacing: Spacing.half) {
                Button("按钮") {}
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(color)
            }
        }
    }

    func caseCell<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.half)
        .padding(.vertical, Spacing.half)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
    }

    /// 根据当前颜色亮度返回可读性更高的前景色，用于背景示例中的对比演示。
    func readableForegroundColor() -> Color {
        let resolved = spec.provider().resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return Color(uiColor: .label)
        }
        let luminance = 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
        return luminance > 0.6 ? .black : .white
    }

    func linearize(_ channel: CGFloat) -> CGFloat {
        if channel <= 0.03928 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }
}

#Preview {
    NavigationStack {
        SystemColorsTestView()
    }
}
#endif
