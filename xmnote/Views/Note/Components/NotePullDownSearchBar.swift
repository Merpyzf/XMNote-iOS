/**
 * [INPUT]: 依赖 SwiftUI Binding 同步当前分类搜索词和焦点状态，接收可访问性可见态与取消回调闭合父级滚动状态
 * [OUTPUT]: 对 Note 页面提供常驻身份的扁平搜索内容头，支持清除、提交与向父级上报唯一取消意图
 * [POS]: Note 模块页面私有搜索组件，由 NoteCollectionView 控制显隐与分类上下文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 以 SwiftUI 原生输入能力承载分类内搜索，让视觉表面弱于内容而保持完整焦点与清除语义。
struct NotePullDownSearchBar: View {
    @Binding var text: String
    @Binding var isActive: Bool
    let placeholder: String
    let isAccessibilityVisible: Bool
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            searchField

            if isFocused {
                Button(action: cancelSearch) {
                    Text("取消")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .frame(minWidth: Spacing.actionReserved, minHeight: Spacing.actionReserved)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityHidden(!isAccessibilityVisible)
                .accessibilityHint("清空当前搜索并关闭键盘")
            }
        }
        .frame(minHeight: Spacing.actionReserved)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isFocused)
        .accessibilityHidden(!isAccessibilityVisible)
        .onAppear(perform: syncFocusFromExternalState)
        .onChange(of: isFocused) { _, newValue in
            guard isActive != newValue else { return }
            isActive = newValue
        }
        .onChange(of: isActive) { _, newValue in
            guard isFocused != newValue else { return }
            isFocused = newValue
        }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.half) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textHint)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { isFocused = false }
                .accessibilityHidden(!isAccessibilityVisible)
                .accessibilityLabel(placeholder)

            if !text.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textHint)
                        .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(!isAccessibilityVisible)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, Spacing.base)
        .frame(maxWidth: .infinity, minHeight: Spacing.actionReserved)
        .background {
            RoundedRectangle(cornerRadius: NoteSearchLayout.cornerRadius, style: .continuous)
                .fill(Color.surfaceCard.opacity(isFocused
                                                ? NoteSearchLayout.focusedSurfaceOpacity
                                                : NoteSearchLayout.idleSurfaceOpacity))
                .frame(height: NoteSearchLayout.visualHeight)
        }
        .contentShape(Rectangle())
    }

    /// 清除当前关键词后维持输入焦点，方便用户立即输入新的查询。
    private func clearSearch() {
        text = ""
        isFocused = true
    }

    /// 取消按钮只上报操作意图，清词、失焦和滚动收口统一由父级状态机原子协调。
    private func cancelSearch() {
        onCancel()
    }

    /// 外部状态恢复时只同步一次焦点，不在普通重绘期间反复抢占第一响应者。
    private func syncFocusFromExternalState() {
        guard isFocused != isActive else { return }
        isFocused = isActive
    }
}

private enum NoteSearchLayout {
    static let visualHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 10
    static let idleSurfaceOpacity = 0.58
    static let focusedSurfaceOpacity = 0.82
}
