/**
 * [INPUT]: 依赖 SwiftUI Binding 同步搜索文本与激活态，依赖 UIKit UISearchBar 提供系统输入、清除和提交语义
 * [OUTPUT]: 对 Personal 管理页提供 PersonalManagementSearchBar，以 minimal 系统外观统一随内容滚动的局部搜索
 * [POS]: Views/Personal/Components 的模块内共享搜索桥接，被标签、分组与来源管理页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// Personal 管理页共享的系统内联搜索栏，保持 UIKit 第一响应者与 SwiftUI 页面状态双向同步。
struct PersonalManagementSearchBar: UIViewRepresentable {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let isEnabled: Bool
    private let onSubmit: () -> Void

    /// 注入搜索文本、激活态、提示文案与提交回调，建立管理页一致的搜索交互。
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

    /// 创建稳定协调器，使 UIKit delegate 在 SwiftUI 更新后仍持有最新 Binding 与回调。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建 minimal 系统搜索栏，保留系统放大镜与输入框内清除按钮，不显示独立取消按钮。
    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .minimal
        searchBar.showsCancelButton = false
        searchBar.tintColor = .label
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.spellCheckingType = .no
        searchBar.returnKeyType = .search
        searchBar.searchTextField.tintColor = .label
        searchBar.searchTextField.clearButtonMode = .whileEditing
        searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        searchBar.accessibilityIdentifier = "personal.management.search"
        return searchBar
    }

    /// 将页面状态对齐到系统搜索栏；焦点请求延后到下一主线程周期，避免在 SwiftUI 更新期修改第一响应者。
    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        context.coordinator.parent = self

        if searchBar.text != text {
            searchBar.text = text
        }
        if searchBar.placeholder != prompt {
            searchBar.placeholder = prompt
        }
        if searchBar.showsCancelButton {
            searchBar.setShowsCancelButton(false, animated: false)
        }
        searchBar.searchTextField.accessibilityLabel = prompt
        searchBar.isUserInteractionEnabled = isEnabled
        searchBar.searchTextField.isEnabled = isEnabled
        searchBar.alpha = isEnabled ? 1 : PersonalManagementSearchBarMetrics.disabledOpacity

        context.coordinator.synchronizeFocus(
            of: searchBar,
            shouldBeActive: isEnabled && isActive
        )
    }

    /// 移除搜索栏时取消焦点与 delegate，避免滚动头离场后继续回写页面状态。
    static func dismantleUIView(_ searchBar: UISearchBar, coordinator: Coordinator) {
        coordinator.invalidatePendingFocusRequest()
        searchBar.searchTextField.resignFirstResponder()
        searchBar.delegate = nil
    }

    /// 承接 UISearchBarDelegate 事件并去重回写 SwiftUI Binding，保持输入与外部刷新的单一状态语义。
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: PersonalManagementSearchBar
        private var focusRequestID = UUID()

        /// 保存初始页面配置，后续由 updateUIView 替换为最新值。
        init(parent: PersonalManagementSearchBar) {
            self.parent = parent
        }

        /// 仅在第一响应者与目标状态不一致时排队同步，并用请求 ID 屏蔽过期焦点任务。
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

        /// 使之前排队的焦点请求失效，防止快速模式切换后键盘被旧任务重新唤起。
        func invalidatePendingFocusRequest() {
            focusRequestID = UUID()
        }

        /// 用户输入或点击系统清除按钮时立即回写查询；清除不会主动结束第一响应者。
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard parent.text != searchText else { return }
            parent.text = searchText
        }

        /// 开始编辑时对齐激活态，独立取消按钮始终保持隐藏。
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if !parent.isActive {
                parent.isActive = true
            }
            searchBar.setShowsCancelButton(false, animated: false)
        }

        /// 结束编辑时只收起键盘并保留当前查询。
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if parent.isActive {
                parent.isActive = false
            }
        }

        /// Search 键结束编辑并保留结果，再把提交意图交回页面。
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.isActive = false
            searchBar.searchTextField.resignFirstResponder()
            parent.onSubmit()
        }
    }
}

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
        PersonalManagementSearchBar(
            text: $text,
            isActive: $isActive,
            prompt: prompt,
            isEnabled: isEnabled,
            onSubmit: onSubmit
        )
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
    static let disabledOpacity: CGFloat = 0.55
    static let listRowHeight: CGFloat = 56
}
