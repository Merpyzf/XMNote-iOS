/**
 * [INPUT]: 依赖微信读书导入偏好、系统 PresentationDetent/Menu/Toggle 与 iOS 26 Liquid Glass 按钮
 * [OUTPUT]: 对外提供微信读书授权页的可折叠导入操作面板及紧凑/展开 Detent
 * [POS]: Views/Personal/DataImport 的业务私有浮动控制层，不持有授权、获取或持久化逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 微信读书授权页的伴随式操作面板，保持设置、主操作与系统 Sheet 高度语义集中。
struct WereadImportActionPanel: View {
    static let compactDetent = PresentationDetent.custom(WereadImportCompactDetent.self)
    static let expandedDetent = PresentationDetent.custom(WereadImportExpandedDetent.self)
    static let detents: Set<PresentationDetent> = [compactDetent, expandedDetent]

    @Binding var selectedDetent: PresentationDetent
    let bottomSafeAreaInset: CGFloat
    let recentBookCount: Int
    let importsReadingTime: Bool
    let onlyBooksWithNotes: Bool
    let primaryTitle: String
    let showsPrimaryProgress: Bool
    let isPrimaryDisabled: Bool
    let areSettingsDisabled: Bool
    let onRecentBookCountChange: (Int) -> Void
    let onImportsReadingTimeChange: (Bool) -> Void
    let onOnlyBooksWithNotesChange: (Bool) -> Void
    let onPrimaryAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let recentBookOptions = [-1, 5, 10, 20, 30, 60, 100]

    private enum Layout {
        static let settingsRowMinimumHeight: CGFloat = 50
        static let primaryActionReservedHeight: CGFloat = 62
        static let collapsedContentOffset: CGFloat = 8
    }

    private var isExpanded: Bool {
        selectedDetent == Self.expandedDetent
    }

    var body: some View {
        GeometryReader { geometry in
            let expansionProgress = expansionProgress(for: geometry)

            ZStack(alignment: .bottom) {
                settingsContent
                    .disabled(areSettingsDisabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.bottom, Layout.primaryActionReservedHeight)
                    .opacity(expansionProgress)
                    .offset(
                        y: reduceMotion
                            ? Spacing.none
                            : Layout.collapsedContentOffset * (1 - expansionProgress)
                    )
                    .allowsHitTesting(expansionProgress > 0.98)
                    .accessibilityHidden(expansionProgress < 0.5)

                primaryButton
                    .offset(y: -collapseTranslation(for: geometry))
            }
            .padding(.horizontal, Spacing.double)
            .padding(.top, Spacing.screenEdge)
            .padding(.bottom, Spacing.screenEdge)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "导入选项" : "导入操作")
        .accessibilityAction(named: Text(isExpanded ? "收起导入面板" : "展开导入选项")) {
            selectedDetent = isExpanded ? Self.compactDetent : Self.expandedDetent
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                settingsRows
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
        } else {
            settingsRows
        }
    }

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            bookRangeRow

            materialToggleRow(
                title: "只获取有笔记的书",
                isOn: Binding(
                    get: { onlyBooksWithNotes },
                    set: onOnlyBooksWithNotesChange
                )
            )

            materialToggleRow(
                title: "同时获取阅读时长",
                isOn: Binding(
                    get: { importsReadingTime },
                    set: onImportsReadingTimeChange
                )
            )

            if importsReadingTime {
                Text("只使用微信读书返回的时长，不覆盖手动计时记录")
                    .font(AppTypography.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bookRangeRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    materialRowTitle("书籍范围")
                    bookRangeMenu
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, Spacing.cozy)
            } else {
                HStack(spacing: Spacing.base) {
                    materialRowTitle("书籍范围")
                    Spacer(minLength: Spacing.base)
                    bookRangeMenu
                }
            }
        }
        .frame(minHeight: Layout.settingsRowMinimumHeight)
    }

    private var bookRangeMenu: some View {
        Menu {
            Picker("书籍范围", selection: bookRangeSelection) {
                ForEach(Self.recentBookOptions, id: \.self) { option in
                    Text(Self.bookRangeTitle(option))
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: Spacing.half) {
                Text(bookRangeTitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "chevron.down")
                    .font(AppTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(
                minWidth: 88,
                minHeight: InteractionMetrics.minimumTouchTarget,
                alignment: .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("书籍范围，当前\(bookRangeTitle)")
        .accessibilityHint("打开选项菜单")
    }

    private var bookRangeSelection: Binding<Int> {
        Binding(
            get: { recentBookCount },
            set: { value in
                guard value != recentBookCount else { return }
                onRecentBookCountChange(value)
            }
        )
    }

    private func materialToggleRow(title: LocalizedStringResource, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            materialRowTitle(title)
        }
        .tint(Color.appTint)
        .frame(minHeight: Layout.settingsRowMinimumHeight)
    }

    private func materialRowTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(AppTypography.headline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            HStack(spacing: Spacing.cozy) {
                if showsPrimaryProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primaryActionForeground)
                }

                Text(primaryTitle)
                    .font(AppTypography.headline)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Color.appTint)
        .disabled(isPrimaryDisabled)
        .accessibilityLabel(primaryTitle)
    }

    private var bookRangeTitle: String {
        Self.bookRangeTitle(recentBookCount)
    }

    /// 将系统 Sheet 的实时拖拽高度映射为内容展开进度，使内容与 Detent 位移保持同一手势节奏。
    private func expansionProgress(for geometry: GeometryProxy) -> CGFloat {
        let compactHeight = dynamicTypeSize.isAccessibilitySize
            ? WereadImportPanelLayout.accessibilityCompactHeight
            : WereadImportPanelLayout.compactHeight
        let contentHeight = visibleContentHeight(for: geometry)
        let travel = WereadImportPanelLayout.expandedHeight - compactHeight
        guard travel > 0 else { return 1 }
        return min(max((contentHeight - compactHeight) / travel, 0), 1)
    }

    /// 只补偿 Sheet 折叠造成的可见高度损失，保留展开态原生底部安全区与系统留白。
    private func collapseTranslation(for geometry: GeometryProxy) -> CGFloat {
        max(WereadImportPanelLayout.expandedHeight - visibleContentHeight(for: geometry), 0)
    }

    /// 以系统拖拽期间持续变化的安全区反推出当前真正可见的面板内容高度。
    private func visibleContentHeight(for geometry: GeometryProxy) -> CGFloat {
        let collapseInset = max(geometry.safeAreaInsets.bottom - bottomSafeAreaInset, 0)
        return geometry.size.height - collapseInset
    }

    nonisolated private static func bookRangeTitle(_ count: Int) -> String {
        count < 0 ? "全部书籍" : "最近 \(count) 本"
    }
}

private enum WereadImportPanelLayout {
    static let compactHeight: CGFloat = 108
    static let accessibilityCompactHeight: CGFloat = 152
    static let expandedHeight: CGFloat = 272
}

private struct WereadImportCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        let preferredHeight = context.dynamicTypeSize.isAccessibilitySize
            ? WereadImportPanelLayout.accessibilityCompactHeight
            : WereadImportPanelLayout.compactHeight
        return min(preferredHeight, context.maxDetentValue)
    }
}

private struct WereadImportExpandedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        guard !context.dynamicTypeSize.isAccessibilitySize else {
            return context.maxDetentValue
        }
        return min(WereadImportPanelLayout.expandedHeight, context.maxDetentValue)
    }
}
