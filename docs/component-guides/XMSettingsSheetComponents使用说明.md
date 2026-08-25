# XMSettingsSheetComponents 迁移说明

`XMSettingsSheetComponents.swift` 已按职责拆分，旧符号不得继续用于新增代码。

## 快速接入

- 卡片式配置页面：使用 `XMSettingsPage`、`XMSettingsSection`、`XMSettingsGroup` 和已验证行型，详见 `docs/component-guides/XMSettingsComponents使用说明.md`。
- 通用业务 Sheet：使用 `XMSheetScaffold`，详见 `docs/component-guides/XMSheetScaffold使用说明.md`。

```bash
python3 scripts/design-system/ds.py catalog --symbol Settings
python3 scripts/design-system/ds.py catalog --symbol Sheet
```

## 参数说明

旧符号没有兼容参数或转发层：

| 旧符号 | 当前入口 |
| --- | --- |
| `XMSettingsPageScaffold` | Sheet 使用 `XMSheetScaffold`；配置主页面使用 `XMSettingsPage` |
| `XMSettingsGroupCard` | `XMSettingsGroup` |
| `XMSettingsNavigationRow` | 保留为页面私有业务组合，当前不设公共万能行 |
| `XMSettingsValueMenuRow` | `xmnote/UIComponents/Settings/XMSettingsRows.swift` |
| `XMSettingsToggleRow` | `xmnote/UIComponents/Settings/XMSettingsRows.swift` |
| `XMSettingsChoiceChip` | 保留为需要它的功能私有组件 |
| `XMSettingsDivider` | `xmnote/UIComponents/Settings/XMSettingsGroup.swift` |

## 示例

旧代码迁移时先判断页面关系，不做机械重命名：

```swift
// 配置主页面
XMSettingsPage {
    XMSettingsSection("显示") {
        XMSettingsGroup {
            settingsContent
        }
    }
}

// 业务 Sheet
XMSheetScaffold(title: "显示设置", onClose: { dismiss() }) {
    settingsContent
}
```

## 常见问题

### 1. 为什么保留这份文件？

用于让历史链接和搜索结果明确指向新入口，避免 AI 或开发者从旧文档恢复已删除的单体组件。

### 2. 可以重新增加兼容 typealias 吗？

不可以。旧类型混合了配置页面与业务 Sheet 两种职责；恢复别名会重新制造模糊入口。

### 3. 旧导航行应迁到哪里？

先保留在使用页面。只有至少两个独立页面证明相同语义、状态边界和交互后，才在 `UIComponents/Settings` 新增专用行型。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
