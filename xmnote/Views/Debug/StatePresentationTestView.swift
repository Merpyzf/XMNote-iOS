#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 StatePresentationCatalogView、DesignTokens 与 SwiftUI 环境/Transaction 覆盖能力，接收测试人员选择的外观、字号和 Reduce Motion 配置
 * [OUTPUT]: 对外提供 StatePresentationTestView，集中展示并交互验收全部通用状态视觉
 * [POS]: Views/Debug 的通用状态测试页，仅存在于 DEBUG 构建，不进入生产导航
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 通用状态测试页把验收控制限制在目录区域，避免改变测试中心自身环境。
struct StatePresentationTestView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var selectedAppearance: StatePresentationTestAppearance = .system
    @State private var selectedTextSize: StatePresentationTestTextSize = .standard
    @State private var forcesReduceMotion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                controls
                previewRegion
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .scrollBounceBehavior(.always)
        .background(Color.surfacePage)
        .navigationTitle("通用状态展示")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text("验收控制")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text("以下设置只作用于组件预览区域，测试中心控制区继续跟随系统。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("外观", selection: $selectedAppearance) {
                    ForEach(StatePresentationTestAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Picker("字号", selection: $selectedTextSize) {
                    ForEach(StatePresentationTestTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("模拟 Reduce Motion", isOn: $forcesReduceMotion)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)

                Text(reduceMotionDescription)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var previewRegion: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text("组件预览")
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.textPrimary)
                Text("当前：\(selectedAppearance.title) · \(selectedTextSize.title) · \(effectiveReduceMotion ? "Reduce Motion" : "标准动效")")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StatePresentationCatalogView()
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfacePage)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        }
        .environment(\.colorScheme, previewColorScheme)
        .environment(\.dynamicTypeSize, selectedTextSize.dynamicTypeSize)
        .transaction { transaction in
            if effectiveReduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }

    private var previewColorScheme: ColorScheme {
        selectedAppearance.colorScheme ?? systemColorScheme
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcesReduceMotion
    }

    private var reduceMotionDescription: String {
        if systemReduceMotion {
            return "系统已开启 Reduce Motion；预览会保持无动画切换。"
        }
        return forcesReduceMotion
            ? "预览区域已强制使用无动画状态切换。"
            : "预览区域使用组件默认的 0.16 秒淡入淡出。"
    }
}

/// 测试页外观选项只覆盖预览子树的 colorScheme 环境。
private enum StatePresentationTestAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "系统"
        case .light:
            "浅色"
        case .dark:
            "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

/// 测试页提供三个有代表性的动态字号档位，覆盖普通与辅助功能排版。
private enum StatePresentationTestTextSize: String, CaseIterable, Identifiable {
    case standard
    case extraLarge
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "标准"
        case .extraLarge:
            "特大"
        case .accessibility:
            "辅助"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard:
            .large
        case .extraLarge:
            .xxxLarge
        case .accessibility:
            .accessibility3
        }
    }
}

#Preview {
    NavigationStack {
        StatePresentationTestView()
    }
}
#endif
