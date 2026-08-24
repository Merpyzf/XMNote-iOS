/**
 * [INPUT]: 依赖 DesignTokens 的语义色与状态呈现尺寸，接收业务侧提供的展示文案和动作闭包
 * [OUTPUT]: 对外提供 XMStateRole、XMStateAction 与通用状态默认图标/颜色映射
 * [POS]: UIComponents/Foundation/StatePresentation 的共享语义模型，被完整状态、紧凑状态与局部提示条复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 内容不可用的展示语义，只描述呈现角色，不持有业务加载阶段或数据状态。
enum XMStateRole: Hashable {
    case instruction
    case empty
    case noResults
    case failure

    var defaultSystemImage: String {
        switch self {
        case .instruction:
            "info.circle"
        case .empty:
            "tray"
        case .noResults:
            "magnifyingglass"
        case .failure:
            "exclamationmark.triangle"
        }
    }

    var iconColor: Color {
        switch self {
        case .instruction, .empty, .noResults:
            .textHint
        case .failure:
            .feedbackWarning
        }
    }
}

/// 状态呈现中的单一主要动作，把标题、可选图标与执行入口绑定为不可拆分的配置。
struct XMStateAction {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let perform: () -> Void

    /// 创建状态动作；闭包由页面状态 owner 执行，组件本身不启动异步任务或修改业务状态。
    init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// 状态动作的统一按钮标签，确保文字和可选 SF Symbol 在三类组件中采用同一结构。
struct XMStateActionLabel: View {
    let action: XMStateAction

    var body: some View {
        if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
        } else {
            Text(action.title)
        }
    }
}
