/**
 * [INPUT]: 依赖 SwiftUI Binding 同步搜索文本与激活态，依赖 UIKit UISearchBar 提供系统输入、清除与提交语义
 * [OUTPUT]: 对外提供 XMSystemSearchBar，供 Sheet 与页面固定搜索区复用原生 iOS 搜索外观和焦点生命周期
 * [POS]: UIComponents/Controls/Search 的系统搜索桥接；不持有业务查询状态，不决定搜索节流或数据来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 将系统搜索栏的文本、焦点与提交事件桥接到 SwiftUI，同时保留 UIKit 原生视觉与可访问性。
@MainActor
struct XMSystemSearchBar: UIViewRepresentable {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let accessibilityIdentifier: String?
    private let isEnabled: Bool
    private let onSubmit: () -> Void

    /// 注入搜索状态和提交回调；框内清除保留输入焦点，Search 键提交后结束输入。
    init(
        text: Binding<String>,
        isActive: Binding<Bool>,
        prompt: String,
        accessibilityIdentifier: String? = nil,
        isEnabled: Bool = true,
        onSubmit: @escaping () -> Void = { }
    ) {
        self._text = text
        self._isActive = isActive
        self.prompt = prompt
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    /// 创建稳定协调器，使 UIKit delegate 始终通过最新 Binding 回写页面状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建 minimal 样式系统搜索栏，由系统负责圆角、图标、清除按钮与动态字体。
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

    /// 只同步变化的外部值；第一响应者切换延后执行，避免在 SwiftUI 更新期重入 UIKit。
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
        searchBar.searchTextField.accessibilityIdentifier = accessibilityIdentifier

        context.coordinator.synchronizeFocus(
            of: searchBar,
            shouldBeActive: isEnabled && isActive
        )
    }

    /// 移除搜索栏时取消待执行焦点请求，并结束输入和 delegate 回写。
    static func dismantleUIView(_ searchBar: UISearchBar, coordinator: Coordinator) {
        coordinator.invalidatePendingFocusRequest()
        searchBar.searchTextField.resignFirstResponder()
        searchBar.delegate = nil
    }

    /// 承接 UISearchBarDelegate 事件，并把输入、提交与焦点生命周期同步回 SwiftUI。
    @MainActor
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: XMSystemSearchBar
        private var focusRequestID = UUID()

        /// 保存初始组件配置，后续由 updateUIView 替换为最新值。
        init(parent: XMSystemSearchBar) {
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

        /// 使已排队的焦点同步失效，保证快速聚焦、结束输入或离场时以最新状态为准。
        func invalidatePendingFocusRequest() {
            focusRequestID = UUID()
        }

        /// 用户输入或点击系统清除按钮时去重回写查询，不改变当前焦点。
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard parent.text != searchText else { return }
            parent.text = searchText
        }

        /// 开始编辑时同步激活态；搜索栏只保留框内系统清除按钮。
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if !parent.isActive {
                parent.isActive = true
            }
        }

        /// 结束编辑时保持页面激活态与第一响应者一致。
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if parent.isActive {
                parent.isActive = false
            }
        }

        /// Search 键先把提交意图交还业务页面，再结束当前输入会话。
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.onSubmit()
            if parent.isActive {
                parent.isActive = false
            }
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}

#Preview("系统搜索栏") {
    @Previewable @State var text = ""
    @Previewable @State var isActive = false

    VStack {
        XMSystemSearchBar(
            text: $text,
            isActive: $isActive,
            prompt: "搜索书籍"
        )
        Spacer()
    }
    .padding(Spacing.screenEdge)
    .background(Color.surfaceSheet)
}
