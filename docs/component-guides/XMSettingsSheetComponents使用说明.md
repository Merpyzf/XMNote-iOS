# XMSettingsSheetComponents 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMSettingsSheetComponents.swift`
- 角色：通用设置 Sheet 组件组，统一标题栏、分组卡片、跳转行、菜单行与开关行。
- 适用场景：业务设置 Sheet、轻量偏好编辑页、需要复用项目设置视觉的弹层。
- 边界：只提供视觉与交互外壳，不直接保存设置，也不访问 Repository。

## 快速接入
```swift
XMSettingsPageScaffold(
    title: "回顾设置",
    subtitle: "书摘范围与卡片样式",
    onClose: { dismiss() }
) {
    VStack(spacing: Spacing.comfortable) {
        XMSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                XMSettingsNavigationRow(
                    title: "书籍范围",
                    value: viewModel.bookScopeSummary,
                    action: { activeSheet = .books }
                )
                XMSettingsValueMenuRow(
                    title: "显示顺序",
                    value: viewModel.settings.sortRule.title,
                    options: NoteReviewSortRule.allCases,
                    selection: viewModel.settings.sortRule,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: updateSortRule
                )
            }
        }
    }
}
```

## 参数说明
| 组件 | 关键参数 | 说明 |
| --- | --- | --- |
| `XMSettingsPageScaffold` | `title`、`subtitle`、`onClose`、`content` | 设置页骨架，提供居中标题、可选副标题、右侧关闭按钮和滚动内容区。 |
| `XMSettingsGroupCard` | `content` | 设置分组容器，统一卡片背景、圆角和内边距。 |
| `XMSettingsNavigationRow` | `title`、`value`、`action` | 可进入子选择器或子 Sheet 的设置行。 |
| `XMSettingsValueMenuRow` | `title`、`value`、`options`、`selection`、`optionTitle`、`optionImage`、`onSelect` | 离散选项菜单行，内部使用 `Menu + Picker`。 |
| `XMSettingsToggleRow` | `title`、`isOn` | 开关设置行，使用项目品牌色 tint。 |

## 示例

### 示例 1：开关设置
```swift
XMSettingsGroupCard {
    XMSettingsToggleRow(
        title: "自动同步",
        isOn: $viewModel.isAutoSyncEnabled
    )
}
```

### 示例 2：跳转到选择器
```swift
XMSettingsNavigationRow(
    title: "标签范围",
    value: viewModel.tagScopeSummary,
    action: { activeSheet = .tags }
)
```

### 示例 3：带系统图标的菜单项
```swift
XMSettingsValueMenuRow(
    title: "排序",
    value: selection.title,
    options: SortRule.allCases,
    selection: selection,
    optionTitle: { $0.title },
    optionImage: { $0.systemImage },
    onSelect: { selection = $0 }
)
```

## 常见问题

### 1. 组件会自动保存设置吗？
不会。所有写入都应在业务 ViewModel 或 Repository 中完成，组件只负责触发回调。

### 2. 什么时候用 `XMSettingsNavigationRow`？
当右侧值需要打开 BookPicker、标签选择 Sheet 或下一层页面时使用。简单枚举选择优先使用 `XMSettingsValueMenuRow`。

### 3. 可以把普通页面也包进 `XMSettingsPageScaffold` 吗？
不建议。它面向 Sheet 风格设置页，主页面应继续使用所在模块的页面壳层。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
