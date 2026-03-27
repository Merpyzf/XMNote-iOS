/**
 * [INPUT]: 依赖 RichTextFormat、DesignTokens 与 SwiftUI 基础组件，承接书摘编辑工具栏的动作定义与渲染约束
 * [OUTPUT]: 对外提供 NoteToolbarActionID、NoteToolbarIconAction、NoteToolbarIconStrip，统一主编辑页与全屏编辑页工具栏动作顺序和显隐动画
 * [POS]: Views/Note/Components 页面私有工具栏构件，确保 Android → iOS 工具栏优先级顺序与动画反馈一致
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

enum NoteToolbarActionID: String, CaseIterable, Identifiable {
    case undo
    case redo
    case cursorLeft
    case cursorRight
    case fullScreen
    case ocr
    case choiceImage
    case indent
    case bold
    case highlight
    case underlined
    case italic
    case strikeThrough
    case formatClear

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .undo:
            return "arrow.uturn.backward"
        case .redo:
            return "arrow.uturn.forward"
        case .cursorLeft:
            return "chevron.left"
        case .cursorRight:
            return "chevron.right"
        case .fullScreen:
            return "arrow.up.left.and.arrow.down.right"
        case .ocr:
            return "text.viewfinder"
        case .choiceImage:
            return "photo.on.rectangle.angled"
        case .indent:
            return "increase.indent"
        case .bold:
            return "bold"
        case .highlight:
            return "highlighter"
        case .underlined:
            return "underline"
        case .italic:
            return "italic"
        case .strikeThrough:
            return "strikethrough"
        case .formatClear:
            return "textformat"
        }
    }

    var format: RichTextFormat? {
        switch self {
        case .bold:
            return .bold
        case .highlight:
            return .highlight
        case .underlined:
            return .underline
        case .italic:
            return .italic
        case .strikeThrough:
            return .strikethrough
        default:
            return nil
        }
    }

    var group: Int {
        switch self {
        case .undo, .redo, .cursorLeft, .cursorRight:
            return 0
        case .fullScreen, .ocr, .choiceImage:
            return 1
        case .indent:
            return 2
        case .bold, .highlight, .underlined, .italic, .strikeThrough:
            return 3
        case .formatClear:
            return 4
        }
    }

    static let androidPriorityOrder: [NoteToolbarActionID] = [
        .undo,
        .redo,
        .cursorLeft,
        .cursorRight,
        .fullScreen,
        .ocr,
        .choiceImage,
        .indent,
        .bold,
        .highlight,
        .underlined,
        .italic,
        .strikeThrough,
        .formatClear,
    ]
}

struct NoteToolbarIconAction: Identifiable {
    let id: NoteToolbarActionID
    let isEnabled: Bool
    let isActive: Bool
    let handler: () -> Void

    var identity: String { id.rawValue }
}

struct NoteToolbarIconStrip: View {
    let actions: [NoteToolbarIconAction]
    var dividerOpacity: Double = 0.16

    var body: some View {
        HStack(spacing: Spacing.tight) {
            ForEach(Array(actions.enumerated()), id: \.element.identity) { index, action in
                if shouldInsertDivider(before: index) {
                    toolbarDivider
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                toolbarIconButton(for: action)
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: actions.map(\.identity))
    }

    private func shouldInsertDivider(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return actions[index - 1].id.group != actions[index].id.group
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(dividerOpacity))
            .frame(width: 1, height: 18)
    }

    private func toolbarIconButton(for action: NoteToolbarIconAction) -> some View {
        Button(action: action.handler) {
            Image(systemName: action.id.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(action.isEnabled ? Color.textPrimary : Color.textHint)
                .frame(width: 34, height: 34)
                .background(
                    action.isActive ? Color.brand.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .accessibilityLabel(action.id.systemImage)
    }
}
