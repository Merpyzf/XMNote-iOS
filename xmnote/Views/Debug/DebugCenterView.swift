#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖设计系统展厅、StatePresentation、RichText、Heatmap、图表、系统反馈、选择、搜索、图片、阅读日历与其他调试页面
 * [OUTPUT]: 对外提供 DebugCenterView（测试中心列表页）
 * [POS]: Debug 测试入口页，集中展示所有控件测试项，由 PersonalView 跳转进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct DebugCenterView: View {

    // MARK: - Data

    private struct DebugItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
        let destination: AnyView
    }

    private let items: [DebugItem] = [
        DebugItem(
            icon: "square.grid.2x2",
            title: "设计系统展厅",
            subtitle: "核心令牌、组件状态、适配环境与专项验收入口",
            destination: AnyView(DesignSystemGalleryView())
        ),
        DebugItem(
            icon: "textformat",
            title: "富文本编辑器",
            subtitle: "格式能力与 HTML 往返一致性",
            destination: AnyView(RichTextTestView())
        ),
        DebugItem(
            icon: "text.alignleft",
            title: "长文本披露",
            subtitle: "正式末行内联展开组件的主题、行数与富文本验收",
            destination: AnyView(FadeOverflowTextTestView())
        ),
        DebugItem(
            icon: "chart.dots.scatter",
            title: "阅读热力图",
            subtitle: "周热力图与 Android 阅读详情月历的渲染、定位和配色验收",
            destination: AnyView(HeatmapTestView())
        ),
        DebugItem(
            icon: "chart.bar.xaxis",
            title: "月度阅读图表",
            subtitle: "Android 同款展开/收起、全局比例与文本对齐验收",
            destination: AnyView(MonthlyReadingChartTestView())
        ),
        DebugItem(
            icon: "clock.arrow.circlepath",
            title: "阅读历程组件",
            subtitle: "状态节点、时间间隔、动态字体与交互权限验收",
            destination: AnyView(ReadingStatusTimelineTestView())
        ),
        DebugItem(
            icon: "rectangle.stack",
            title: "通用状态展示",
            subtitle: "完整、紧凑、Inline、加载与五阶段的浅深色和动态字体验收",
            destination: AnyView(StatePresentationTestView())
        ),
        DebugItem(
            icon: "rectangle.center.inset.filled.badge.plus",
            title: "System Alert",
            subtitle: "XMSystemAlert 基础设施、系统颜色语义与轻输入场景验证",
            destination: AnyView(SystemAlertTestView())
        ),
        DebugItem(
            icon: "bubble.left.and.text.bubble.right",
            title: "Toast 提示",
            subtitle: "XMToast 统一入口、底部短驻留提示、状态与安全区验证",
            destination: AnyView(PopupViewToastTestView())
        ),
        DebugItem(
            icon: "star.circle",
            title: "评分组件",
            subtitle: "Fluent 星形、半星步进、交互热区与浅深色验证",
            destination: AnyView(RatingBarTestView())
        ),
        DebugItem(
            icon: "books.vertical",
            title: "书籍选择",
            subtitle: "Android 20 个选书场景在 iOS 统一 BookPicker 中的覆盖与消费验证",
            destination: AnyView(BookSelectionTestView())
        ),
        DebugItem(
            icon: "checkmark.circle",
            title: "选择动效",
            subtitle: "SF Symbols 绘制出现/消失与自定义选择反馈验证",
            destination: AnyView(SelectionMotionTestView())
        ),
        DebugItem(
            icon: "music.note.list",
            title: "Apple Music 转场",
            subtitle: "Bottom Accessory 液态玻璃退场的 XMNote 对照与纯系统框架归因",
            destination: AnyView(AppleMusicTransitionLabView())
        ),
        DebugItem(
            icon: "rectangle.split.3x1",
            title: "范围选择控件",
            subtitle: "2-5 项单选范围、数量、长文案、浅深色与玻璃样式验证",
            destination: AnyView(XMScopeSelectorTestView())
        ),
        DebugItem(
            icon: "clock.arrow.circlepath",
            title: "搜索历史组件",
            subtitle: "空态、短词、长词、删除、清空、展开与 iOS 26 样式验证",
            destination: AnyView(SearchHistoryTestView())
        ),
        DebugItem(
            icon: "magnifyingglass.circle",
            title: "Searchable 系统复现",
            subtitle: "iOS 26 Search Tab 焦点、呈现与延迟写入 text 的最小复现",
            destination: AnyView(SearchableSystemBugReproView())
        ),
        DebugItem(
            icon: "rectangle.portrait.and.arrow.right",
            title: "滚动边缘覆盖层",
            subtitle: "顶部/底部柔化、背景、强度、高度与深色模式验证",
            destination: AnyView(XMScrollEdgeChromeTestView())
        ),
        DebugItem(
            icon: "square.grid.3x3",
            title: "书架手动排序",
            subtitle: "LazyVGrid 拖拽、置顶边界、搜索禁用与模拟写入验证",
            destination: AnyView(BookReorderSandboxTestView())
        ),
        DebugItem(
            icon: "photo.stack",
            title: "图片加载",
            subtitle: "静态图/GIF/失败链路与缓存来源观测",
            destination: AnyView(ImageLoadingTestView())
        ),
        DebugItem(
            icon: "globe.asia.australia.fill",
            title: "网页 HTML 抓取",
            subtitle: "WebView/HTTP 双通道、Cookie 复用与 DOM 探针验证",
            destination: AnyView(WebHTMLFetchTestView())
        ),
        DebugItem(
            icon: "text.viewfinder",
            title: "系统取词",
            subtitle: "系统键盘 OCR 按钮 + 可用性/语言列表验证",
            destination: AnyView(CameraTextCaptureTestView())
        ),
        DebugItem(
            icon: "doc.text.viewfinder",
            title: "百度 OCR",
            subtitle: "官方 SDK + 图片裁切 + 参数持久化 + 富文本回填验证",
            destination: AnyView(BaiduOCRTestView())
        ),
        DebugItem(
            icon: "rectangle.3.group",
            title: "JX 图片浏览器",
            subtitle: "UIKit 核心浏览器 + SwiftUI 缩略图墙 Zoom 转场验证",
            destination: AnyView(JXPhotoBrowserTestView())
        ),
        DebugItem(
            icon: "books.vertical",
            title: "阅读日历封面堆叠",
            subtitle: "扇形层级、阴影分离与网格溢出效果验证",
            destination: AnyView(ReadCalendarCoverStackTestView())
        ),
        DebugItem(
            icon: "rectangle.stack",
            title: "书摘回顾卡堆",
            subtitle: "BigUIPaging Core + XMNote 自定义卡堆动效与长文滚动仲裁",
            destination: AnyView(NoteReviewPagingTestView())
        ),
        DebugItem(
            icon: "book.closed",
            title: "书籍封面样式",
            subtitle: "薄厚边样式、尺寸降级阈值与浅深色对照验证",
            destination: AnyView(BookCoverStyleTestView())
        ),
        DebugItem(
            icon: "rectangle.stack",
            title: "书籍分组封面",
            subtitle: "书盒候选样式、多/单/空封面与列表行浅深色验证",
            destination: AnyView(BookGroupCoverTestView())
        ),
        DebugItem(
            icon: "books.vertical.fill",
            title: "封面阅读进度条",
            subtitle: "玻璃轨道、尺寸适配与进度动画验证",
            destination: AnyView(BookCoverProgressBarTestView())
        ),
        DebugItem(
            icon: "pin.square",
            title: "书封角标效果",
            subtitle: "置顶/数量毛玻璃参数与阅读状态纯色角标验证",
            destination: AnyView(BookCoverBadgeEffectTestView())
        ),
        DebugItem(
            icon: "slider.horizontal.2.square",
            title: "首页顶部胶囊",
            subtitle: "正式基线与 A/B/C 原生 Liquid Glass 候选的真实首页上下文对比",
            destination: AnyView(TopBarActionStyleLabTestView())
        ),
        DebugItem(
            icon: "camera.filters",
            title: "iOS 26 Liquid Glass（液态玻璃）",
            subtitle: "图片背景文本、工具栏、参数预设、截图对比与 FPS 观测",
            destination: AnyView(LiquidGlassLabTestView())
        ),
        DebugItem(
            icon: "paintpalette",
            title: "系统颜色语义",
            subtitle: "按语义分组查看 iOS 系统颜色与真实案例用法",
            destination: AnyView(SystemColorsTestView())
        ),
        DebugItem(
            icon: "timeline.selection",
            title: "时间线卡片",
            subtitle: "7 种事件卡片样式与时间线装饰器",
            destination: AnyView(TimelineCardsTestView())
        ),
        DebugItem(
            icon: "calendar.badge.clock",
            title: "时间线日历-Horizon",
            subtitle: "Vendor 源码集成 + 范围/选中/月切换/跳转/marker 渲染验证",
            destination: AnyView(TimelineCalendarHorizonTestView())
        ),
    ]

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                cardGroup("测试项") {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        debugRow(item, isLast: index == items.count - 1)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .navigationTitle("测试中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Components

    private func cardGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, Spacing.half)

            CardContainer {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    private func debugRow(_ item: DebugItem, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            NavigationLink(destination: item.destination) {
                HStack {
                    Image(systemName: item.icon)
                        .font(.body)
                        .foregroundStyle(Color.appTint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider()
                    .padding(.leading, Spacing.contentEdge + 24 + Spacing.base)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DebugCenterView()
    }
}
#endif
