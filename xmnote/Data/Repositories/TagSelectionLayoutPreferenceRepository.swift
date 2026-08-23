/**
 * [INPUT]: 依赖 UserDefaults 与 TagSelectionLayoutMode 持久化通用标签选择器布局偏好
 * [OUTPUT]: 对外提供 TagSelectionLayoutPreferenceRepository，读取和保存全局标签选择布局
 * [POS]: Data 层窄范围偏好 Repository，避免视图直接访问 UserDefaults 或引入通用设置基建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 标签选择布局的本地轻量持久化入口，所有复用场景共享同一个跨启动偏好。
nonisolated struct TagSelectionLayoutPreferenceRepository: TagSelectionLayoutPreferenceRepositoryProtocol {
    private let defaults: UserDefaults
    private let key = "tag-selection.layout-mode.v1"

    /// 注入 UserDefaults，默认使用 App 标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取上次选择的布局；缺失或原始值非法时稳定回退列表。
    func fetchLayoutMode() -> TagSelectionLayoutMode {
        guard let rawValue = defaults.string(forKey: key),
              let layoutMode = TagSelectionLayoutMode(rawValue: rawValue) else {
            return .list
        }
        return layoutMode
    }

    /// 立即保存布局偏好，使后续页面与下次 App 启动保持一致。
    func saveLayoutMode(_ layoutMode: TagSelectionLayoutMode) {
        defaults.set(layoutMode.rawValue, forKey: key)
    }
}
