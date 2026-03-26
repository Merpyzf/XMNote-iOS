#if DEBUG
/**
 * [INPUT]: 依赖 Foundation 管理系统中心弹窗测试场景、输入值与日志状态
 * [OUTPUT]: 对外提供 SystemAlertTestViewModel，统一编排 XMSystemAlert 测试页的消息型、输入型与 item 驱动用例
 * [POS]: Debug 模块系统中心弹窗测试页状态编排，隔离测试场景切换与日志记录
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum SystemAlertScenario: String, CaseIterable, Identifiable {
    case singleAction
    case decision
    case destructive
    case longMessage
    case textField
    case itemDriven

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleAction:
            "单按钮提示"
        case .decision:
            "双按钮决策"
        case .destructive:
            "警告操作"
        case .longMessage:
            "长文案"
        case .textField:
            "轻输入"
        case .itemDriven:
            "item 驱动"
        }
    }

    var subtitle: String {
        switch self {
        case .singleAction:
            "验证默认色按钮和基础关闭语义"
        case .decision:
            "验证取消 / 确认顺序与颜色"
        case .destructive:
            "验证 destructive 红色与默认按钮并存"
        case .longMessage:
            "验证较长正文在系统 Alert 中的呈现"
        case .textField:
            "验证文本输入、键盘类型和回填"
        case .itemDriven:
            "验证用 presentation model 驱动的关闭链路"
        }
    }
}

@Observable
final class SystemAlertTestViewModel {
    struct PresentedItem: Identifiable {
        let id = UUID()
        let scenario: SystemAlertScenario
    }

    var currentScenario: SystemAlertScenario = .singleAction
    var isSystemAlertPresented = false
    var presentedItem: PresentedItem?
    var inputText = "https://example.com"
    var eventLog: [String] = []

    func present(_ scenario: SystemAlertScenario) {
        currentScenario = scenario
        if scenario == .itemDriven {
            presentedItem = PresentedItem(scenario: scenario)
        } else {
            isSystemAlertPresented = true
        }
        appendLog("打开: \(scenario.title)")
    }

    func primaryActionTapped(for scenario: SystemAlertScenario) {
        appendLog("主动作: \(scenario.title)")
    }

    func destructiveActionTapped(for scenario: SystemAlertScenario) {
        appendLog("破坏动作: \(scenario.title)")
    }

    func secondaryActionTapped(for scenario: SystemAlertScenario) {
        appendLog("次动作: \(scenario.title)")
    }

    func recordDismissal(for scenario: SystemAlertScenario) {
        appendLog("关闭: \(scenario.title)")
    }

    private func appendLog(_ message: String) {
        eventLog.insert(message, at: 0)
        if eventLog.count > 12 {
            eventLog.removeLast(eventLog.count - 12)
        }
    }
}
#endif
