/**
 * [INPUT]: 依赖 PopupView 呈现能力、SwiftUI Observation 与 DesignTokens 语义样式，统一承接轻量消息提示的角色、时长、位置与动效
 * [OUTPUT]: 对外提供 XMToastRole、XMToastPlacement、XMToastMessage、XMToastCenter 与 View.xmToastHost(center:) 统一消息提示入口
 * [POS]: UIComponents/Foundation 的全局 Toast 基础设施，隐藏 PopupView 具体实现并收敛消息提示样式、布局、动效与交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import PopupView
import SwiftUI

/// 轻量消息提示的语义角色，决定图标、颜色与默认展示时长。
enum XMToastRole: String, Sendable {
    case success
    case warning
    case error
    case info
    case processing

    var symbolName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .processing:
            return "arrow.triangle.2.circlepath"
        }
    }

    var tintColor: Color {
        switch self {
        case .success:
            return .feedbackSuccess
        case .warning:
            return .feedbackWarning
        case .error:
            return .feedbackError
        case .info:
            return .brandDeep
        case .processing:
            return .brand
        }
    }

    var title: String {
        switch self {
        case .success:
            return "成功"
        case .warning:
            return "警告"
        case .error:
            return "错误"
        case .info:
            return "信息"
        case .processing:
            return "处理中"
        }
    }

    var defaultDuration: TimeInterval? {
        switch self {
        case .success, .info:
            return 1.8
        case .warning:
            return 2.4
        case .error:
            return 3.2
        case .processing:
            return nil
        }
    }

    var isProcessing: Bool {
        self == .processing
    }
}

/// 轻量消息提示的位置策略，默认底部浮动，调试页可切换顶部验证安全区。
enum XMToastPlacement: String, CaseIterable, Identifiable, Sendable {
    case bottom
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom:
            return "底部"
        case .top:
            return "顶部"
        }
    }

    var popupPosition: Popup.Position {
        switch self {
        case .bottom:
            return .bottom
        case .top:
            return .top
        }
    }

    var appearAnimation: Popup.AppearAnimation {
        switch self {
        case .bottom:
            return .bottomSlide
        case .top:
            return .topSlide
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .bottom:
            return XMToastLayout.bottomVerticalPadding
        case .top:
            return Spacing.base
        }
    }
}

/// 单条 Toast 消息模型，业务代码只描述语义与文案，不接触具体呈现组件。
struct XMToastMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: XMToastRole
    let text: String
    let placement: XMToastPlacement
    let duration: TimeInterval?

    init(
        id: UUID = UUID(),
        role: XMToastRole,
        text: String,
        placement: XMToastPlacement = .bottom,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.placement = placement
        self.duration = duration
    }

    /// 构造成功提示，默认短驻留并位于底部。
    static func success(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) -> XMToastMessage {
        XMToastMessage(role: .success, text: text, placement: placement, duration: duration)
    }

    /// 构造警告提示，默认比成功态稍长以保证可读。
    static func warning(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) -> XMToastMessage {
        XMToastMessage(role: .warning, text: text, placement: placement, duration: duration)
    }

    /// 构造错误提示，仍保持非阻塞，适合轻量失败反馈。
    static func error(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) -> XMToastMessage {
        XMToastMessage(role: .error, text: text, placement: placement, duration: duration)
    }

    /// 构造信息提示，用于不需要确认的轻量状态说明。
    static func info(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) -> XMToastMessage {
        XMToastMessage(role: .info, text: text, placement: placement, duration: duration)
    }

    /// 构造处理中提示，默认不自动隐藏，直到被新消息替换或手动关闭。
    static func processing(
        _ text: String,
        placement: XMToastPlacement = .bottom
    ) -> XMToastMessage {
        XMToastMessage(role: .processing, text: text, placement: placement)
    }

    var resolvedDuration: TimeInterval? {
        guard !role.isProcessing else { return nil }
        return duration ?? role.defaultDuration
    }

    var accessibilityLabel: String {
        "\(role.title)：\(text)"
    }
}

/// 全局 Toast 状态中心；调用方只负责提交最新消息，旧消息会被直接替换。
@MainActor
@Observable
final class XMToastCenter {
    private(set) var current: XMToastMessage?

    #if DEBUG
    /// Debug 演示页专用开关，用于预览 Reduce Motion 下的动效降级。
    var debugReducesMotion = false
    #endif

    /// 展示一条完整 Toast 消息；连续调用时采用 newest-wins，不做队列堆叠。
    func show(_ message: XMToastMessage) {
        current = message
    }

    /// 展示指定角色的 Toast，并允许调用方覆盖默认时长与位置。
    func show(
        _ role: XMToastRole,
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) {
        show(XMToastMessage(role: role, text: text, placement: placement, duration: duration))
    }

    /// 展示成功提示，适合保存、同步、排序完成等轻量结果。
    func success(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) {
        show(.success, text, duration: duration, placement: placement)
    }

    /// 展示警告提示，适合可继续操作但需要注意的状态。
    func warning(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) {
        show(.warning, text, duration: duration, placement: placement)
    }

    /// 展示错误提示，适合不需要中心弹窗确认的轻量失败反馈。
    func error(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) {
        show(.error, text, duration: duration, placement: placement)
    }

    /// 展示信息提示，适合不改变任务流的状态说明。
    func info(
        _ text: String,
        duration: TimeInterval? = nil,
        placement: XMToastPlacement = .bottom
    ) {
        show(.info, text, duration: duration, placement: placement)
    }

    /// 展示处理中提示；调用方应在完成后用结果 Toast 替换。
    func processing(
        _ text: String,
        placement: XMToastPlacement = .bottom
    ) {
        show(XMToastMessage.processing(text, placement: placement))
    }

    /// 关闭当前 Toast；传入 id 时只关闭匹配消息，避免旧任务误关新消息。
    func dismiss(id: XMToastMessage.ID? = nil) {
        guard id == nil || current?.id == id else { return }
        current = nil
    }
}

extension View {
    /// 在根视图上挂载统一 Toast Host，业务页面不应直接使用 PopupView。
    func xmToastHost(center: XMToastCenter) -> some View {
        modifier(XMToastHostModifier(center: center))
    }
}

private struct XMToastHostModifier: ViewModifier {
    let center: XMToastCenter
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func body(content: Content) -> some View {
        content
            .popup(item: toastItem) { message in
                XMToastBubble(message: message) {
                    center.dismiss(id: message.id)
                }
            } customize: {
                $0
                    .type(.floater(
                        verticalPadding: currentPlacement.verticalPadding,
                        horizontalPadding: Spacing.screenEdge,
                        useSafeAreaInset: true
                    ))
                    .position(currentPlacement.popupPosition)
                    .appearFrom(shouldReduceMotion ? .none : currentPlacement.appearAnimation)
                    .disappearTo(shouldReduceMotion ? .none : currentPlacement.appearAnimation)
                    .animation(shouldReduceMotion ? .easeOut(duration: 0.01) : .snappy(duration: 0.22))
                    .autohideIn(center.current?.resolvedDuration)
                    .dragToDismiss(true)
                    .closeOnTap(true)
                    .closeOnTapOutside(false)
                    .allowTapThroughBG(true)
                    .displayMode(.window)
            }
    }

    private var toastItem: Binding<XMToastMessage?> {
        Binding(
            get: { center.current },
            set: { newValue in
                guard let newValue else {
                    center.dismiss()
                    return
                }
                center.show(newValue)
            }
        )
    }

    private var currentPlacement: XMToastPlacement {
        center.current?.placement ?? .bottom
    }

    private var shouldReduceMotion: Bool {
        #if DEBUG
        return accessibilityReduceMotion || center.debugReducesMotion
        #else
        return accessibilityReduceMotion
        #endif
    }
}

private struct XMToastBubble: View {
    let message: XMToastMessage
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .center, spacing: Spacing.cozy) {
                icon

                Text(message.text)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .frame(maxWidth: XMToastLayout.maxWidth)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle.opacity(0.58), lineWidth: CardStyle.borderWidth)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.accessibilityLabel)
        .accessibilityHint("轻点关闭")
    }

    @ViewBuilder
    private var icon: some View {
        if message.role.isProcessing {
            ProgressView()
                .controlSize(.small)
                .tint(Color.brand)
                .frame(width: XMToastLayout.iconFrame, height: XMToastLayout.iconFrame)
        } else {
            Image(systemName: message.role.symbolName)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(message.role.tintColor)
                .frame(width: XMToastLayout.iconFrame, height: XMToastLayout.iconFrame)
        }
    }
}

private enum XMToastLayout {
    static let maxWidth: CGFloat = 340
    static let iconFrame: CGFloat = 24
    static let bottomFloatingGap: CGFloat = Spacing.base
    static let bottomChromeReservation: CGFloat = ImmersiveBottomChromeStyle.controlHeight
        + ImmersiveBottomChromeStyle.ornamentTopPadding
        + ImmersiveBottomChromeStyle.minimumBottomPadding
    static let bottomVerticalPadding: CGFloat = bottomChromeReservation + bottomFloatingGap
}
