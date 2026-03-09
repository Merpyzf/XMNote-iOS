/**
 * [INPUT]: 依赖 UIKit 的 UIResponder 标准编辑动作与 UIAction 工厂，依赖 UIKeyInput 约束目标响应者
 * [OUTPUT]: 对外提供 XMCameraTextCaptureSupport，共享系统相机取词能力判断、动作生成与触发入口
 * [POS]: Infra 模块的系统能力桥接层，隔离 SwiftUI/页面层对 UIKit selector 细节的直接依赖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 统一封装系统 Live Text 相机取词能力，供编辑器和测试页复用。
@MainActor
enum XMCameraTextCaptureSupport {

    /// 判断目标响应者当前是否支持系统相机取词。
    static func canCapture(on responder: (UIResponder & UIKeyInput)?) -> Bool {
        guard let responder else { return false }
        return responder.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil)
    }

    /// 为目标响应者生成标准编辑动作，便于菜单或按钮直接复用系统能力。
    static func makeAction(
        for responder: UIResponder & UIKeyInput,
        identifier: UIAction.Identifier? = nil
    ) -> UIAction {
        UIAction.captureTextFromCamera(responder: responder, identifier: identifier)
    }

    /// 触发系统相机取词。若控件尚未获得焦点，先提升为 first responder。
    static func trigger(on responder: UIResponder & UIKeyInput) {
        guard canCapture(on: responder) else { return }
        if !responder.isFirstResponder {
            _ = responder.becomeFirstResponder()
        }
        responder.captureTextFromCamera(nil)
    }
}
