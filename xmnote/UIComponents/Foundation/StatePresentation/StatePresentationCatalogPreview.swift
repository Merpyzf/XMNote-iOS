/**
 * [INPUT]: 依赖 StatePresentation 组件族与 DesignTokens，组合各角色、布局、tone、加载样式和阶段切换
 * [OUTPUT]: 在 DEBUG 构建中提供可被测试中心与 SwiftUI Preview 复用的 StatePresentationCatalogView
 * [POS]: UIComponents/Foundation/StatePresentation 的单一视觉验收目录，不参与生产导航或业务状态编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

#if DEBUG
import SwiftUI

/// 状态组件视觉目录集中覆盖完整状态、紧凑状态、局部横幅、加载视觉和阶段宿主。
struct StatePresentationCatalogView: View {
    @State private var selectedPhase: StatePresentationCatalogPhase = .placeholder
    @State private var lastActionFeedback = "尚未触发示例操作"

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.section) {
            catalogSection("完整状态", subtitle: "页面、Sheet 与列表背景使用的四种角色") {
                contentStates
            }

            catalogSection("紧凑状态 · Centered", subtitle: "卡片或分区内的居中状态") {
                compactCenteredStates
            }

            catalogSection("紧凑状态 · Card", subtitle: "需要稳定表层与左对齐信息层级的局部状态") {
                compactCardStates
            }

            catalogSection("局部横幅", subtitle: "已有内容继续可用时的 neutral、warning 与 error") {
                inlineBanners
            }

            catalogSection("加载状态", subtitle: "统一的 inline 与 card 视觉，显隐时序仍由外部管理") {
                loadingStates
            }

            catalogSection("阶段宿主", subtitle: "交互切换 placeholder、loading、content、empty 与 failure") {
                phaseHost
            }

            Label(lastActionFeedback, systemImage: "hand.tap")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contentStates: some View {
        VStack(spacing: Spacing.base) {
            contentStateSample("Instruction") {
                XMContentStateView(
                    role: .instruction,
                    title: "选择一本书",
                    message: "选择后会在这里展示对应内容。"
                )
            }

            contentStateSample("Empty · 业务图标覆盖") {
                XMContentStateView(
                    role: .empty,
                    title: "暂无书籍",
                    message: "添加书籍后会显示在这里。",
                    systemImage: "books.vertical"
                )
            }

            contentStateSample("No Results") {
                XMContentStateView(
                    role: .noResults,
                    title: "没有找到结果",
                    message: "尝试更换关键词或清除筛选条件。"
                )
            }

            contentStateSample("Failure · 长文案与可用操作") {
                XMContentStateView(
                    role: .failure,
                    title: "暂时无法加载",
                    message: "网络连接不稳定，部分内容尚未返回。请检查连接后再试一次；这段说明用于验证辅助功能字号和窄屏环境下可以完整换行，不会被固定高度裁切。",
                    action: enabledAction("重试完整状态")
                )
            }
        }
    }

    private var compactCenteredStates: some View {
        VStack(spacing: Spacing.base) {
            catalogSample("Instruction · 业务图标覆盖") {
                XMCompactStateView(
                    role: .instruction,
                    title: "扫描书籍条码",
                    message: "将条码放入取景框后开始识别。",
                    systemImage: "barcode.viewfinder"
                )
            }

            catalogSample("Empty") {
                XMCompactStateView(
                    role: .empty,
                    title: "暂无阅读记录",
                    message: "完成一次阅读后会显示在这里。"
                )
            }

            catalogSample("No Results") {
                XMCompactStateView(
                    role: .noResults,
                    title: "没有匹配的内容",
                    message: "尝试输入更短的关键词。"
                )
            }

            catalogSample("Failure · 禁用操作") {
                XMCompactStateView(
                    role: .failure,
                    title: "正在重新连接",
                    message: "恢复操作执行期间保持不可重复触发。",
                    action: XMStateAction(
                        "正在重试",
                        systemImage: "arrow.clockwise",
                        isEnabled: false
                    ) {}
                )
            }
        }
    }

    private var compactCardStates: some View {
        VStack(spacing: Spacing.base) {
            catalogSample("Instruction") {
                XMCompactStateView(
                    role: .instruction,
                    title: "输入搜索条件",
                    message: "支持书名、作者或 ISBN。",
                    style: .card
                )
            }

            catalogSample("Empty") {
                XMCompactStateView(
                    role: .empty,
                    title: "暂无分区内容",
                    message: "添加内容后会显示在这里。",
                    style: .card
                )
            }

            catalogSample("No Results") {
                XMCompactStateView(
                    role: .noResults,
                    title: "没有匹配的书摘",
                    message: "可以清除筛选条件后重新查看。",
                    style: .card
                )
            }

            catalogSample("Failure · 可用操作") {
                XMCompactStateView(
                    role: .failure,
                    title: "搜索失败",
                    message: "错误说明可能较长，组件会保持正文换行，并让恢复操作继续作为独立的无障碍元素。",
                    action: enabledAction("重新搜索"),
                    style: .card
                )
            }
        }
    }

    private var inlineBanners: some View {
        VStack(spacing: Spacing.base) {
            XMInlineStatusBanner("筛选条件已更新。")
            XMInlineStatusBanner(
                "部分内容暂时无法刷新，当前已有内容仍可继续浏览；长说明应在窄屏和辅助功能字号下自然换行。",
                tone: .warning
            )
            XMInlineStatusBanner(
                "保存失败，请检查网络后重试。",
                tone: .error,
                action: enabledAction("重试保存")
            )
        }
    }

    private var loadingStates: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            catalogSample("Inline") {
                LoadingStateView("正在加载…")
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            catalogSample("Card") {
                LoadingStateView("正在加载…", style: .card)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var phaseHost: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text("当前阶段")
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(selectedPhase.explanation)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.base)

                Picker("当前阶段", selection: $selectedPhase) {
                    ForEach(StatePresentationCatalogPhase.allCases) { phase in
                        Text(phase.title).tag(phase)
                    }
                }
                .pickerStyle(.menu)
            }

            LoadPhaseHost(
                phase: selectedPhase.loadPhase,
                content: {
                    CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            Label("内容已加载", systemImage: "checkmark.circle")
                                .font(AppTypography.headlineSemibold)
                                .foregroundStyle(Color.textPrimary)
                            Text("这是用于验证 LoadPhaseHost 内容阶段的示例区域。")
                                .font(AppTypography.subheadline)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Spacing.contentEdge)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                    }
                },
                placeholder: {
                    StatePresentationCatalogPlaceholder()
                },
                loading: {
                    VStack {
                        LoadingStateView("正在加载阶段内容…", style: .card)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                },
                empty: { message in
                    XMCompactStateView(
                        role: .empty,
                        title: "暂无内容",
                        message: message
                    )
                },
                failure: { message in
                    XMCompactStateView(
                        role: .failure,
                        title: "加载失败",
                        message: message,
                        action: enabledAction("重试阶段加载"),
                        style: .card
                    )
                }
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// 以统一标题和说明组织目录分组，便于逐项核对状态层级。
    private func catalogSection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(title)
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
    }

    /// 为完整状态提供可自然增高的验收表层，避免辅助字号被固定高度裁切。
    private func contentStateSample<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                sampleTitle(title)
                content()
                    .frame(minHeight: 230)
            }
            .padding(Spacing.base)
        }
    }

    /// 为不需要额外表层的样例增加稳定标题，不干扰被测组件本身的布局。
    private func catalogSample<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            sampleTitle(title)
            content()
        }
    }

    private func sampleTitle(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
    }

    /// 创建可交互的示例动作，并把触发结果留在目录底部供人工核对。
    private func enabledAction(_ title: String) -> XMStateAction {
        XMStateAction(title, systemImage: "arrow.clockwise") {
            lastActionFeedback = "已触发「\(title)」"
        }
    }
}

/// 目录中的阶段选项只驱动展示层，不模拟 Repository 或 ViewModel 状态。
private enum StatePresentationCatalogPhase: String, CaseIterable, Identifiable {
    case placeholder
    case loading
    case content
    case empty
    case failure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .placeholder:
            "Placeholder"
        case .loading:
            "Loading"
        case .content:
            "Content"
        case .empty:
            "Empty"
        case .failure:
            "Failure"
        }
    }

    var explanation: String {
        switch self {
        case .placeholder:
            "数据尚未返回，先保持静默占位。"
        case .loading:
            "读取持续超过阈值后展示加载反馈。"
        case .content:
            "可信内容已经可用。"
        case .empty:
            "读取完成且数据源确认为空。"
        case .failure:
            "没有可用内容且读取失败。"
        }
    }

    var loadPhase: LoadPhase {
        switch self {
        case .placeholder:
            .placeholder
        case .loading:
            .loading
        case .content:
            .content
        case .empty:
            .empty(message: "完成一次操作后会显示在这里。")
        case .failure:
            .error(message: "模拟错误信息用于核对恢复动作和状态切换。")
        }
    }
}

/// 静默占位样例只表达容器几何，不复用通用空态语义。
private struct StatePresentationCatalogPlaceholder: View {
    var body: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                    .fill(Color.controlFillSecondary)
                    .frame(maxWidth: 180, minHeight: 18)
                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                    .fill(Color.controlFillSecondary)
                    .frame(maxWidth: .infinity, minHeight: 14)
                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                    .fill(Color.controlFillSecondary)
                    .frame(maxWidth: 240, minHeight: 14)
            }
            .padding(Spacing.contentEdge)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        }
        .accessibilityLabel("内容占位阶段")
    }
}

private struct StatePresentationCatalogPreviewHost: View {
    var body: some View {
        ScrollView {
            StatePresentationCatalogView()
                .padding(Spacing.contentEdge)
        }
        .scrollBounceBehavior(.always)
        .background(Color.surfacePage)
    }
}

#Preview("状态目录 · 浅色") {
    StatePresentationCatalogPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("状态目录 · 深色") {
    StatePresentationCatalogPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("状态目录 · 辅助功能字号") {
    StatePresentationCatalogPreviewHost()
        .dynamicTypeSize(.accessibility3)
}
#endif
