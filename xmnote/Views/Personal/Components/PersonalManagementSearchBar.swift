/**
 * [INPUT]: 依赖 SwiftUI Binding 同步搜索文本与激活态，依赖 canonical XMInlineSearchField 提供输入、清除和提交语义
 * [OUTPUT]: 对 Personal 管理页提供 PersonalManagementSearchListRow，将 canonical 搜索框适配到系统 List 行
 * [POS]: Views/Personal/Components 的模块内 List 布局适配层，被分组与来源管理页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 将共享搜索栏接入系统 List 的透明控制 Section，并让输入表面与 16pt 页面基线对齐。
struct PersonalManagementSearchListRow: View {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let isEnabled: Bool
    private let onSubmit: () -> Void

    /// 注入列表搜索状态；Section 需将水平 margin 设为零，由本行统一提供外部间距。
    init(
        text: Binding<String>,
        isActive: Binding<Bool>,
        prompt: String,
        isEnabled: Bool,
        onSubmit: @escaping () -> Void = { }
    ) {
        self._text = text
        self._isActive = isActive
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    var body: some View {
        XMInlineSearchField(
            text: $text,
            isActive: $isActive,
            prompt: prompt,
            cancelPresentation: .hidden,
            onSubmit: onSubmit
        )
        .disabled(!isEnabled)
        .accessibilityIdentifier("personal.management.search")
        .frame(minHeight: PersonalManagementSearchBarMetrics.listRowHeight)
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: Spacing.cozy,
            bottom: 0,
            trailing: Spacing.cozy
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private enum PersonalManagementSearchBarMetrics {
    static let listRowHeight: CGFloat = 56
}
