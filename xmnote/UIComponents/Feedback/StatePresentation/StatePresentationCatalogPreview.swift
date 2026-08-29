/**
 * [INPUT]: 依赖 StatePresentation 组件族与设计系统令牌，使用固定生产场景配置组合页面、局部、保留内容和加载状态
 * [OUTPUT]: 在 DEBUG 构建中提供可被测试中心与 SwiftUI Preview 复用的 StatePresentationCatalogView
 * [POS]: UIComponents/Feedback/StatePresentation 的公共状态验收目录，不依赖业务 View 或模拟 Repository
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

#if DEBUG
import SwiftUI

/// 公共状态目录按真实视觉原型组织页面、局部、保留内容与加载阶段，避免把 API 参数排列误当成产品场景。
struct StatePresentationCatalogView: View {
    @State private var selectedPhase: StatePresentationCatalogPhase = .placeholder
    @State private var lastActionFeedback = "尚未触发示例操作"

    private let pageStatePreviewHeight = StatePresentationCatalogLayout.pageStatePreviewHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            catalogSection(
                "页面状态",
                subtitle: "页面、Sheet 与列表背景中的空数据、搜索、失效和首次读取失败"
            ) {
                pageStates
            }

            catalogSection(
                "局部状态",
                subtitle: "工作台、卡片与分区中的安静状态、前置条件和恢复动作"
            ) {
                compactStates
            }

            catalogSection(
                "保留内容状态",
                subtitle: "刷新、分页或写入失败时保留当前可信内容"
            ) {
                retainedContentStates
            }

            catalogSection(
                "加载阶段",
                subtitle: "读取门闩决定显隐，阶段宿主保持同一页面几何"
            ) {
                loadingStates
                phaseHost
            }

            Label(lastActionFeedback, systemImage: "hand.tap")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(.large)
        }
    }

    private var pageStates: some View {
        VStack(spacing: Spacing.base) {
            scenarioSample(
                title: "安静页面空状态",
                production: "书架",
                trigger: "书架为空；目录管理等已有顶部入口的页面使用同一视觉",
                level: "页面",
                component: "XMContentStateView · empty",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(role: .empty, title: "暂无书籍")
            }

            scenarioSample(
                title: "可继续的空状态",
                production: "当日阅读",
                trigger: "当天没有记录，仍可发起打卡",
                level: "页面",
                component: "XMContentStateView · empty · action",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .empty,
                    title: "当天没有阅读记录",
                    systemImage: "calendar.badge.clock",
                    action: action("打卡")
                )
            }

            scenarioSample(
                title: "搜索无结果",
                production: "书架搜索",
                trigger: "搜索完成且没有匹配书籍",
                level: "页面",
                component: "XMContentStateView · noResults",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .noResults,
                    title: "没有匹配的书籍"
                )
            }

            scenarioSample(
                title: "筛选修正",
                production: "笔记回顾",
                trigger: "当前范围没有可回顾书摘",
                level: "页面",
                component: "XMContentStateView · noResults · action",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .noResults,
                    title: "暂无可回顾书摘",
                    systemImage: "line.3.horizontal.decrease.circle",
                    action: action("调整范围")
                )
            }

            scenarioSample(
                title: "内容已失效",
                production: "书评详情",
                trigger: "目标书评不存在或已删除",
                level: "页面",
                component: "XMContentStateView · instruction",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .instruction,
                    title: "书评不存在或已删除",
                    systemImage: "questionmark.circle"
                )
            }

            scenarioSample(
                title: "首次读取失败",
                production: "书评详情",
                trigger: "没有可信内容且读取失败",
                level: "页面",
                component: "XMContentStateView · failure · retry",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .failure,
                    title: "暂时无法加载书评",
                    action: action("重试")
                )
            }

            scenarioSample(
                title: "长标题与禁用恢复动作",
                production: "阅读详情",
                trigger: "长中文标题换行；重试请求已发出且暂不可重复触发",
                level: "页面",
                component: "XMContentStateView · failure · disabled",
                minimumContentHeight: pageStatePreviewHeight
            ) {
                XMContentStateView(
                    role: .failure,
                    title: "暂时无法加载这本书的阅读进度与历史记录",
                    action: XMStateAction(
                        "重试",
                        isEnabled: false,
                        perform: {}
                    )
                )
            }
        }
    }

    private var compactStates: some View {
        VStack(spacing: Spacing.base) {
            scenarioSample(
                title: "安静局部空状态",
                production: "书籍工作台 · 目录",
                trigger: "当前书籍没有章节",
                level: "局部居中",
                component: "XMCompactStateView · centered · empty"
            ) {
                XMCompactStateView(
                    role: .empty,
                    title: "暂无目录"
                )
            }

            scenarioSample(
                title: "局部搜索无结果",
                production: "书籍工作台 · 目录",
                trigger: "目录搜索完成且没有匹配章节",
                level: "局部居中",
                component: "XMCompactStateView · centered · noResults"
            ) {
                XMCompactStateView(
                    role: .noResults,
                    title: "没有匹配的目录"
                )
            }

            scenarioSample(
                title: "局部读取失败",
                production: "阅读时间线",
                trigger: "列表首次读取失败",
                level: "局部居中",
                component: "XMCompactStateView · centered · failure"
            ) {
                XMCompactStateView(
                    role: .failure,
                    title: "暂时无法加载时间线",
                    action: action("重试")
                )
            }

            scenarioSample(
                title: "局部前置条件",
                production: "书籍搜索 · 站点验证",
                trigger: "外部来源要求先完成验证",
                level: "局部卡片",
                component: "XMCompactStateView · card · instruction"
            ) {
                XMCompactStateView(
                    role: .instruction,
                    title: "需要完成验证",
                    message: "完成后会继续搜索",
                    systemImage: "checkmark.shield",
                    action: action("去验证"),
                    style: .card
                )
            }

            scenarioSample(
                title: "局部卡片无结果",
                production: "书籍搜索",
                trigger: "在线搜索完成且没有匹配书籍",
                level: "局部卡片",
                component: "XMCompactStateView · card · noResults"
            ) {
                XMCompactStateView(
                    role: .noResults,
                    title: "没有匹配的书籍",
                    style: .card
                )
            }

            scenarioSample(
                title: "局部卡片失败",
                production: "书籍搜索",
                trigger: "当前来源读取失败",
                level: "局部卡片",
                component: "XMCompactStateView · card · failure"
            ) {
                XMCompactStateView(
                    role: .failure,
                    title: "当前来源搜索失败",
                    action: action("重试"),
                    style: .card
                )
            }

            scenarioSample(
                title: "局部下一步说明",
                production: "选书器 · 本地书库",
                trigger: "没有可选书籍，下一步不在当前区域",
                level: "局部卡片",
                component: "XMCompactStateView · card · empty"
            ) {
                XMCompactStateView(
                    role: .empty,
                    title: "还没有可选书籍",
                    message: "请先添加书籍",
                    style: .card
                )
            }

            scenarioSample(
                title: "局部继续动作",
                production: "选书器 · 已选书籍",
                trigger: "已选列表为空，可返回继续选择",
                level: "局部卡片",
                component: "XMCompactStateView · card · empty · action"
            ) {
                XMCompactStateView(
                    role: .empty,
                    title: "暂无已选书籍",
                    systemImage: "books.vertical",
                    action: action("继续选择"),
                    style: .card
                )
            }
        }
    }

    private var retainedContentStates: some View {
        scenarioSample(
            title: "内容仍可用",
            production: "阅读日历、书架、书摘列表、书评详情",
            trigger: "读取或写入失败，但已有内容继续可信",
            level: "内容内",
            component: "XMInlineStatusBanner"
        ) {
            trustedContentPreview

            VStack(alignment: .leading, spacing: Spacing.base) {
                bannerVariant("阅读日历｜刷新失败｜可重试") {
                    XMInlineStatusBanner(
                        "阅读记录暂未更新",
                        tone: .warning,
                        action: action("重试")
                    )
                }

                bannerVariant("书架｜写入失败｜无直接动作") {
                    XMInlineStatusBanner(
                        "书架调整未保存",
                        tone: .warning,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                bannerVariant("书摘列表｜刷新失败｜可重试") {
                    XMInlineStatusBanner(
                        "书摘刷新失败",
                        tone: .error,
                        action: action("重试")
                    )
                }

                bannerVariant("书评详情｜删除失败｜无直接动作") {
                    XMInlineStatusBanner(
                        "删除书评失败",
                        tone: .error
                    )
                }

                bannerVariant("书架｜刷新请求进行中｜禁用动作") {
                    XMInlineStatusBanner(
                        "书架刷新失败",
                        tone: .error,
                        action: XMStateAction(
                            "重试",
                            isEnabled: false,
                            perform: {}
                        )
                    )
                }
            }
        }
    }

    private var loadingStates: some View {
        VStack(spacing: Spacing.base) {
            scenarioSample(
                title: "局部静默加载",
                production: "在读首页 · 阅读热力图",
                trigger: "卡片已经存在，局部数据仍在读取",
                level: "局部卡片",
                component: "LoadingStateView · inline · spinner only"
            ) {
                CardContainer(
                    cornerRadius: CornerRadius.containerLarge,
                    showsBorder: false
                ) {
                    LoadingStateView(style: .inline)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }

            scenarioSample(
                title: "局部写入反馈",
                production: "目录管理",
                trigger: "章节重命名正在写入，目录内容仍留在页面",
                level: "页面浮层",
                component: "LoadingStateView · card"
            ) {
                LoadingStateView("正在保存章节…", style: .card)
                    .padding(.top, Spacing.cozy)
            }
        }
    }

    private var phaseHost: some View {
        scenarioSample(
            title: "页面读取阶段",
            production: "书单与内容详情",
            trigger: "同一页面切换占位、加载、内容、空状态和失败",
            level: "页面",
            component: "LoadPhaseHost · XMContentStateView"
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Picker("当前阶段", selection: $selectedPhase) {
                    ForEach(StatePresentationCatalogPhase.allCases) { phase in
                        Text(phase.title).tag(phase)
                    }
                }
                .pickerStyle(.menu)
                .dynamicTypeSize(.large)

                Text(selectedPhase.explanation)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(.large)

                LoadPhaseHost(
                    phase: selectedPhase.loadPhase,
                    content: { trustedContentPreview },
                    placeholder: { StatePresentationCatalogPlaceholder() },
                    loading: {
                        LoadingStateView("正在加载书单…")
                            .frame(maxWidth: .infinity, minHeight: pageStatePreviewHeight)
                    },
                    empty: { message in
                        XMContentStateView(role: .empty, title: message)
                    },
                    failure: { message in
                        XMContentStateView(
                            role: .failure,
                            title: message,
                            action: action("重试")
                        )
                    }
                )
                .frame(maxWidth: .infinity, minHeight: pageStatePreviewHeight)
                .background(Color.surfacePage)
            }
        }
    }

    private var trustedContentPreview: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("已有书摘")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                Text("最近一次成功读取的内容仍可继续查看")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func catalogSection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .dynamicTypeSize(.large)
            content()
        }
    }

    private func scenarioSample<Content: View>(
        title: String,
        production: String,
        trigger: String,
        level: String,
        component: String,
        minimumContentHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(title)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                Text("\(production)｜\(trigger)｜\(level)｜\(component)")
            }
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(.large)

            VStack(alignment: .leading, spacing: Spacing.base) {
                content()
            }
            .frame(
                maxWidth: .infinity,
                minHeight: minimumContentHeight,
                alignment: .topLeading
            )

            Divider()
        }
    }

    private func action(_ title: String) -> XMStateAction {
        XMStateAction(title) {
            lastActionFeedback = "已触发「\(title)」"
        }
    }

    private func bannerVariant<Content: View>(
        _ metadata: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(metadata)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .dynamicTypeSize(.large)
            content()
        }
    }
}

/// 页面状态样例保持固定最小视口；Dynamic Type 只改变内容排版，不放大测试容器基线。
private enum StatePresentationCatalogLayout {
    static let pageStatePreviewHeight: CGFloat = 220
}

/// 目录阶段只驱动固定展示，不模拟 Repository 或 ViewModel。
private enum StatePresentationCatalogPhase: String, CaseIterable, Identifiable {
    case placeholder
    case loading
    case content
    case empty
    case failure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .placeholder: "占位"
        case .loading: "加载"
        case .content: "内容"
        case .empty: "空状态"
        case .failure: "失败"
        }
    }

    var explanation: String {
        switch self {
        case .placeholder: "数据尚未返回，先保持静默占位"
        case .loading: "读取持续超过阈值后展示加载反馈"
        case .content: "可信内容已经可用"
        case .empty: "读取完成且数据源确认为空"
        case .failure: "没有可用内容且读取失败"
        }
    }

    var loadPhase: LoadPhase {
        switch self {
        case .placeholder: .placeholder
        case .loading: .loading
        case .content: .content
        case .empty: .empty(message: "暂无书单")
        case .failure: .error(message: "暂时无法加载书单")
        }
    }
}

/// 静默占位只表达容器几何，不复用通用空态语义。
private struct StatePresentationCatalogPlaceholder: View {
    var body: some View {
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
        .frame(
            maxWidth: .infinity,
            minHeight: StatePresentationCatalogLayout.pageStatePreviewHeight,
            alignment: .leading
        )
        .background(Color.surfacePage)
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
