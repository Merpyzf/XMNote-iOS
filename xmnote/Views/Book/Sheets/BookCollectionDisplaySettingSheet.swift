/**
 * [INPUT]: 依赖 BookCollectionDisplaySetting 持久化配置与 SwiftUI Sheet 展示能力
 * [OUTPUT]: 对外提供 BookCollectionDisplaySettingSheet，按首页书籍显示设置同款 UI 调整书单显示方式、封面排布和统计展示偏好
 * [POS]: Book 模块业务 Sheet，服务书单首页更多菜单中的显示设置入口，不直接承担数据读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单首页显示设置 Sheet，复用书架显示设置的页面骨架和设置行样式。
struct BookCollectionDisplaySettingSheet: View {
    @Binding var setting: BookCollectionDisplaySetting
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "显示设置",
            subtitle: "书单首页",
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                displayGroup
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(settingsReflowAnimation, value: setting.displayMode)
            .animation(settingsReflowAnimation, value: setting.coverArrangement)
            .animation(settingsReflowAnimation, value: setting.showsStatistics)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
    }

    private var displayGroup: some View {
        BookshelfSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                BookshelfSettingsValueMenuRow(
                    title: "显示方式",
                    value: setting.displayMode.title,
                    options: BookCollectionDisplayMode.allCases,
                    selection: setting.displayMode,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: { setting.displayMode = $0 }
                )

                BookshelfSettingsValueMenuRow(
                    title: "封面排布",
                    value: setting.coverArrangement.title,
                    options: BookCollectionCoverArrangement.allCases,
                    selection: setting.coverArrangement,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: { setting.coverArrangement = $0 }
                )

                BookshelfSettingsToggleRow(
                    title: "显示统计信息",
                    isOn: $setting.showsStatistics
                )
            }
        }
    }

    private var settingsReflowAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }
}

private extension BookCollectionCoverArrangement {
    var systemImage: String {
        switch self {
        case .stacked:
            return "square.stack.3d.down.right"
        case .regular:
            return "square.grid.2x2"
        }
    }
}
