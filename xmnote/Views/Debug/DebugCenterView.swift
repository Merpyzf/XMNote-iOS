#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 RichTextTestView、HeatmapTestView、SystemAlertTestView、BookSelectionTestView、ImageLoadingTestView、WebHTMLFetchTestView、CameraTextCaptureTestView、BaiduOCRTestView、JXPhotoBrowserTestView、ReadCalendarCoverStackTestView、BookCoverStyleTestView、BookCoverProgressBarTestView、SystemColorsTestView、TimelineCardsTestView、TimelineCalendarHorizonTestView 作为导航目的地
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
            icon: "textformat",
            title: "富文本编辑器",
            subtitle: "格式能力与 HTML 往返一致性",
            destination: AnyView(RichTextTestView())
        ),
        DebugItem(
            icon: "chart.dots.scatter",
            title: "阅读热力图",
            subtitle: "8 个场景的渲染、交互与颜色适配",
            destination: AnyView(HeatmapTestView())
        ),
        DebugItem(
            icon: "rectangle.center.inset.filled.badge.plus",
            title: "System Alert",
            subtitle: "XMSystemAlert 基础设施、系统颜色语义与轻输入场景验证",
            destination: AnyView(SystemAlertTestView())
        ),
        DebugItem(
            icon: "books.vertical",
            title: "书籍选择",
            subtitle: "Android 20 个选书场景在 iOS 统一 BookPicker 中的覆盖与消费验证",
            destination: AnyView(BookSelectionTestView())
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
            icon: "book.closed",
            title: "书籍封面样式",
            subtitle: "薄厚边样式、尺寸降级阈值与浅深色对照验证",
            destination: AnyView(BookCoverStyleTestView())
        ),
        DebugItem(
            icon: "books.vertical.fill",
            title: "封面阅读进度条",
            subtitle: "玻璃轨道、尺寸适配与进度动画验证",
            destination: AnyView(BookCoverProgressBarTestView())
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
                        .foregroundStyle(Color.brand)
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
