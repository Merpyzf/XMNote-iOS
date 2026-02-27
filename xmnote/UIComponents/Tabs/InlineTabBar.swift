/**
 * [INPUT]: 依赖 SwiftUI 状态绑定与 matchedGeometryEffect 动画能力
 * [OUTPUT]: 对外提供 InlineTabBar 行内标签组件
 * [POS]: UIComponents/Tabs 的基础页内标签组件，用于常规二级切换场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用内嵌标签栏，左对齐、内容自适应宽度、品牌绿下划线指示器
/// 对应 Android 端 TabLayout 的 scrollable + wrap_content 模式
struct InlineTabBar<Tab: Hashable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {

    @Binding var selection: Tab
    let titleProvider: (Tab) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Tab.allCases), id: \.self) { tab in
                tabItem(tab)
            }
        }
    }

    private func tabItem(_ tab: Tab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.snappy) { selection = tab }
        } label: {
            VStack(spacing: 4) {
                Text(titleProvider(tab))
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize()
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.brand)
                        .frame(height: 3)
                        .matchedGeometryEffect(id: "indicator", in: namespace)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

#Preview("InlineTabBar") {
    @Previewable @State var selection: InlineTabBarPreviewTab = .first
    NavigationStack {
        Color.clear
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    InlineTabBar(selection: $selection) { $0.title }
                }
            }
    }
}

private enum InlineTabBarPreviewTab: CaseIterable, Hashable {
    case first, second, third

    var title: String {
        switch self {
        case .first: "标签一"
        case .second: "标签二"
        case .third: "标签三"
        }
    }
}
