/**
 * [INPUT]: 依赖 SwiftUI Binding 同步搜索文本与激活态，依赖 UIKit UISearchBar 提供原生输入、清除、取消与提交语义
 * [OUTPUT]: 对外提供 XMSearchBar，以 minimal 系统外观统一内容区搜索，并保持 UIKit 焦点生命周期与页面状态一致
 * [POS]: UIComponents/Foundation 的系统搜索基础组件，供需要原生 UISearchBar 交互的业务页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 内容区原生搜索栏；系统负责清除与取消按钮的外观、布局和交互动效。
@MainActor
struct XMSearchBar: UIViewRepresentable {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let isEnabled: Bool
    private let onSubmit: () -> Void
    private let onCancel: () -> Void

    /// 注入搜索状态和操作回调；取消搜索会清空关键词并结束输入，但不承担页面关闭语义。
    init(
        text: Binding<String>,
        isActive: Binding<Bool>,
        prompt: String,
        isEnabled: Bool = true,
        onSubmit: @escaping () -> Void = { },
        onCancel: @escaping () -> Void = { }
    ) {
        self._text = text
        self._isActive = isActive
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// 创建稳定协调器，使 UIKit delegate 始终通过最新 Binding 回写页面状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建系统 minimal 搜索栏；不覆盖系统背景、圆角、图标或材质。
    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .minimal
        searchBar.showsCancelButton = false
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.spellCheckingType = .no
        searchBar.returnKeyType = .search
        searchBar.searchTextField.clearButtonMode = .whileEditing
        searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        return searchBar
    }

    /// 仅同步确实变化的外部值；第一响应者切换交给协调器延后执行，避免更新期重入。
    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        context.coordinator.parent = self

        if searchBar.text != text {
            searchBar.text = text
        }
        if searchBar.placeholder != prompt {
            searchBar.placeholder = prompt
        }
        if searchBar.isEnabled != isEnabled {
            searchBar.isEnabled = isEnabled
        }
        searchBar.searchTextField.accessibilityLabel = prompt

        context.coordinator.synchronizeFocus(
            of: searchBar,
            shouldBeActive: isEnabled && isActive
        )
    }

    /// 移除搜索栏时取消待执行焦点任务，并在主线程结束输入和 delegate 回写。
    static func dismantleUIView(_ searchBar: UISearchBar, coordinator: Coordinator) {
        coordinator.invalidatePendingFocusRequest()
        searchBar.searchTextField.resignFirstResponder()
        searchBar.delegate = nil
    }

    /// 承接 UISearchBarDelegate 事件，并让原生取消按钮只随真实编辑生命周期变化。
    @MainActor
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: XMSearchBar
        private var focusRequestID = UUID()

        /// 保存初始组件配置，后续由 updateUIView 替换为最新值。
        init(parent: XMSearchBar) {
            self.parent = parent
        }

        /// 焦点请求延后到下一主线程周期，并用请求 ID 防止过期任务重新唤起键盘。
        func synchronizeFocus(of searchBar: UISearchBar, shouldBeActive: Bool) {
            let isFirstResponder = searchBar.searchTextField.isFirstResponder
            guard isFirstResponder != shouldBeActive else {
                invalidatePendingFocusRequest()
                return
            }

            let requestID = UUID()
            focusRequestID = requestID
            DispatchQueue.main.async { [weak self, weak searchBar] in
                guard let self, let searchBar, self.focusRequestID == requestID else { return }
                if shouldBeActive {
                    searchBar.searchTextField.becomeFirstResponder()
                } else {
                    searchBar.searchTextField.resignFirstResponder()
                }
            }
        }

        /// 使已排队的焦点同步失效，保证快速聚焦、取消或离场时以最新状态为准。
        func invalidatePendingFocusRequest() {
            focusRequestID = UUID()
        }

        /// 用户输入或点击框内系统清除按钮时去重回写查询，不改变当前焦点。
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard parent.text != searchText else { return }
            parent.text = searchText
        }

        /// 开始编辑时显示系统取消按钮；Reduce Motion 下直接落到可见端点。
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if !parent.isActive {
                parent.isActive = true
            }
            setCancelButtonVisible(true, in: searchBar)
        }

        /// 结束编辑时隐藏系统取消按钮，并保持页面激活态与第一响应者一致。
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if parent.isActive {
                parent.isActive = false
            }
            setCancelButtonVisible(false, in: searchBar)
        }

        /// Search 键保留当前查询并结束输入，再把提交意图交还业务页面。
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.onSubmit()
            if parent.isActive {
                parent.isActive = false
            }
            searchBar.searchTextField.resignFirstResponder()
        }

        /// 系统取消按钮只结束搜索会话：清空查询、收起键盘并通知页面附加状态。
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            if !parent.text.isEmpty {
                parent.text = ""
            }
            if searchBar.text?.isEmpty == false {
                searchBar.text = ""
            }
            if parent.isActive {
                parent.isActive = false
            }
            parent.onCancel()
            searchBar.searchTextField.resignFirstResponder()
        }

        /// 只在可见端点变化时调用 UIKit 原生动画，避免 SwiftUI 重绘反复重启动效。
        private func setCancelButtonVisible(_ isVisible: Bool, in searchBar: UISearchBar) {
            guard searchBar.showsCancelButton != isVisible else { return }
            searchBar.setShowsCancelButton(
                isVisible,
                animated: !UIAccessibility.isReduceMotionEnabled
            )
        }
    }
}
