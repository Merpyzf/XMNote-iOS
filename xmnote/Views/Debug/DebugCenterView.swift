#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 RichTextTestView、HeatmapTestView 作为导航目的地
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
        .background(Color.windowBackground)
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
