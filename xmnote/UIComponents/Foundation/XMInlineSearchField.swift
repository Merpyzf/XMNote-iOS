/**
 * [INPUT]: 依赖 SwiftUI Binding 同步搜索文本与焦点激活态，接收提示文案、取消呈现模式、提交和取消回调
 * [OUTPUT]: 对外提供 XMInlineSearchField 与 XMInlineSearchCancelPresentation，以中性内容表面统一搜索、清除、可选外部取消与键盘提交语义
 * [POS]: UIComponents/Foundation 的内容区搜索基础组件，被管理页与笔记页的可滚动搜索头复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 行内搜索的外部取消呈现语义，区分完整搜索模式与常驻筛选工具。
enum XMInlineSearchCancelPresentation: Hashable {
    case automatic
    case hidden
}

/// 内容区搜索输入框；搜索状态属于所在滚动内容，不占用导航栏或底部 Chrome。
struct XMInlineSearchField: View {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let cancelPresentation: XMInlineSearchCancelPresentation
    private let onSubmit: () -> Void
    private let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var cancelButtonWidth = Spacing.actionReserved
    @State private var cancelPresentationProgress: CGFloat = 0
    @FocusState private var isFocused: Bool

    /// 注入搜索文本、焦点状态和操作回调，保持清除、取消与提交行为在页面之间一致。
    init(
        text: Binding<String>,
        isActive: Binding<Bool>,
        prompt: String,
        cancelPresentation: XMInlineSearchCancelPresentation = .automatic,
        onSubmit: @escaping () -> Void = { },
        onCancel: @escaping () -> Void = { }
    ) {
        self._text = text
        self._isActive = isActive
        self.prompt = prompt
        self.cancelPresentation = cancelPresentation
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            searchSurface
                .padding(.trailing, cancelReservedWidth * cancelPresentationProgress)

            cancelButton
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.actionReserved)
        .onAppear(perform: synchronizeInitialPresentation)
        .onChange(of: showsCancelButton) { _, isVisible in
            updateCancelPresentation(isVisible: isVisible, animated: true)
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            guard isEnabled else { return }
            updateCancelPresentation(isVisible: showsCancelButton, animated: false)
        }
        .onChange(of: isFocused) { _, newValue in
            guard isActive != newValue else { return }
            isActive = newValue
        }
        .onChange(of: isActive) { _, newValue in
            guard isFocused != newValue else { return }
            isFocused = newValue
        }
    }

    /// 查询存在时即使键盘已收起也保留取消入口，避免焦点变化先于按钮点击完成。
    private var showsCancelButton: Bool {
        cancelPresentation == .automatic && (isFocused || !text.isEmpty)
    }

    private var cancelReservedWidth: CGFloat {
        cancelButtonWidth + Spacing.cozy
    }

    /// 以稳定的尾部坐标承载取消操作，透明度与搜索表面宽度共享同一个视觉进度。
    @ViewBuilder
    private var cancelButton: some View {
        if cancelPresentation == .automatic {
            Button("取消", action: cancelSearch)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(width: cancelButtonWidth)
                .frame(minHeight: Spacing.actionReserved)
                .contentShape(Rectangle())
                .opacity(cancelPresentationProgress)
                .accessibilityHint("清空当前搜索并关闭键盘")
                .allowsHitTesting(showsCancelButton)
                .accessibilityHidden(!showsCancelButton)
        }
    }

    private var searchSurface: some View {
        HStack(spacing: Spacing.half) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textHint)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit(submitSearch)
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textHint)
                        .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                        .contentShape(Circle())
                }
                .accessibilityLabel("清除搜索")
                .accessibilityHint("清空关键词并继续输入")
            }
        }
        .padding(.leading, Spacing.base)
        .frame(maxWidth: .infinity, minHeight: XMInlineSearchFieldMetrics.touchHeight)
        .background {
            RoundedRectangle(
                cornerRadius: XMInlineSearchFieldMetrics.cornerRadius,
                style: .continuous
            )
            .fill(Color.controlFillSecondary)
            .frame(height: XMInlineSearchFieldMetrics.visualHeight)
        }
        .contentShape(Rectangle())
    }

    /// 清空关键词后维持第一响应者，方便用户连续修正查询。
    private func clearSearch() {
        text = ""
        isFocused = true
        isActive = true
    }

    /// 提交只收起键盘并保留当前结果，业务查询仍由文本 Binding 驱动。
    private func submitSearch() {
        isFocused = false
        isActive = false
        onSubmit()
    }

    /// 取消同时清空关键词和焦点，随后把唯一取消意图交给页面收口附加状态。
    private func cancelSearch() {
        text = ""
        isFocused = false
        isActive = false
        onCancel()
    }

    /// 页面恢复时仅对齐外部焦点状态，不在普通文本刷新期间反复抢占第一响应者。
    private func synchronizeFocusFromExternalState() {
        guard isFocused != isActive else { return }
        isFocused = isActive
    }

    /// 首次挂载或复用时无动画同步焦点与视觉端点，避免页面恢复产生无来源动效。
    private func synchronizeInitialPresentation() {
        synchronizeFocusFromExternalState()
        updateCancelPresentation(
            isVisible: showsCancelButton,
            animated: false
        )
    }

    /// 将取消入口的显示意图映射为可中断视觉进度；Reduce Motion 下立即落到目标端点。
    private func updateCancelPresentation(isVisible: Bool, animated: Bool) {
        let targetProgress: CGFloat = isVisible ? 1 : 0
        guard cancelPresentationProgress != targetProgress else { return }

        if reduceMotion || !animated {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cancelPresentationProgress = targetProgress
            }
            return
        }

        withAnimation(.smooth(duration: XMInlineSearchFieldMetrics.cancelTransitionDuration)) {
            cancelPresentationProgress = targetProgress
        }
    }
}

private enum XMInlineSearchFieldMetrics {
    static let visualHeight: CGFloat = 40
    static let touchHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 12
    static let cancelTransitionDuration = 0.22
}
