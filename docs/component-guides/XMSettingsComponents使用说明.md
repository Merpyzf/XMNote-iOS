# XMSettingsComponents 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Settings/`。
- 角色：为卡片式配置页面提供稳定的页面、分区、分组和已验证行型语法。
- 适用场景：AI 配置、网页端、数据备份、API 集成，以及后续具有同类信息结构的配置页面。
- 边界：组件只负责视觉与交互结构，不读取 Repository、不保存配置，也不把不同业务行压缩成万能参数集合。

## 快速接入

```swift
XMSettingsPage {
    XMSettingsSection("同步") {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                XMSettingsToggleRow(
                    title: "自动同步",
                    isOn: $viewModel.isAutoSyncEnabled
                )

                XMSettingsDivider()

                XMSettingsValueMenuRow(
                    title: "同步频率",
                    value: viewModel.frequency.title,
                    options: SyncFrequency.allCases,
                    selection: viewModel.frequency,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: viewModel.updateFrequency
                )
            }
        }
    }
}
```

页面自己的导航标题、保存按钮和业务反馈继续由页面壳层负责。

## 参数说明

| 组件 | 关键参数 | 说明 |
| --- | --- | --- |
| `XMSettingsPage` | `content` | 统一滚动、全轴回弹、页面背景、横向边距、底部空间和最大内容宽度。 |
| `XMSettingsSection` | `title`、`content` | 使用 `LocalizedStringResource` 表达分区标题，统一标题层级与从属间距。 |
| `XMSettingsGroup` | `presentation`、`horizontalPadding`、`verticalPadding`、`content` | 默认 grouped 卡片并固定使用 `CornerRadius.containerXXL`（24pt）连续圆角；真正的单项设置可显式使用 `.singleItem`。页面不能覆盖 grouped 圆角。 |
| `XMSettingsDivider` | 无 | 同一组内的弱分割线。 |
| `XMSettingsToggleRow` | `title`、`isOn` | 单一标题与开关组成的稳定行型。 |
| `XMSettingsValueMenuRow` | `title`、`value`、`options`、`selection`、`optionTitle`、`optionImage`、`onSelect` | 离散值菜单行；普通菜单使用中性色并提供当前值可访问性描述。 |

## 示例

### 示例 1：独立单项设置

```swift
XMSettingsSection("安全") {
    XMSettingsGroup(presentation: .singleItem) {
        XMSettingsToggleRow(
            title: "访问授权码",
            isOn: $viewModel.requiresAuthorization
        )
    }
}
```

`.singleItem` 只用于没有附属输入、错误或说明内容的唯一顶层设置行。内容增长时应切回 `.grouped`，不要用固定高度维持胶囊外观。

默认 `.grouped` 形态固定使用 24pt 连续圆角。这个轮廓属于所有配置分组共同演进的组件语义，不提供调用方覆盖参数；需要其他圆角的业务表面不应伪装成 `XMSettingsGroup`。

### 示例 2：业务特有的双行设置

```swift
XMSettingsGroup {
    HStack(spacing: Spacing.base) {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("访问授权码")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)

            Text("同一局域网设备无需验证")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }

        Spacer(minLength: Spacing.base)

        Toggle("", isOn: $viewModel.requiresAuthorization)
            .labelsHidden()
    }
    .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
}
```

双行说明、图标、异步状态或凭证输入属于业务组合，不应为了复用而向 `XMSettingsToggleRow` 添加大量可选参数。

### 示例 3：组内多个行型

```swift
XMSettingsGroup {
    VStack(spacing: Spacing.none) {
        providerRow
        XMSettingsDivider()
        modelRow
    }
}
```

分割线只表达同一语义组内的边界。两个独立分区应使用 `XMSettingsSection` 的间距关系，不用 divider 强行连接。

## 常见问题

### 1. 为什么没有通用导航行、图标行或双行行型？

当前跨页面证据只证明了菜单值行和开关行具有稳定接口。其他视觉相似行的业务状态、可访问性描述和交互目标并不相同，保留页面私有组合更容易理解和维护。

### 2. 可以在 Settings 组件里保存 UserDefaults 吗？

不可以。持久化由 ViewModel、Repository 或明确的配置 owner 完成；组件只绑定值或回调。

### 3. 什么时候新增公共设置行？

至少两个独立生产页面存在相同语义、相同状态边界和相同交互后再抽取。新增前先执行：

```bash
python3 scripts/design-system/ds.py catalog --symbol Settings
```

### 4. 可以为某个设置页调整分组圆角吗？

不可以。`XMSettingsGroup` 的 grouped 圆角由组件固定消费 `CornerRadius.containerXXL`。如果某个表面确实不是配置分组，应使用其真实业务组件或页面私有样式，而不是向设置组件重新开放视觉参数。

### 5. 如何处理 Dynamic Type？

优先使用最小高度和 `fixedSize(horizontal: false, vertical: true)`，让内容自然增长。不要用固定高度、缩小到不可读字号或单行裁剪维持视觉整齐。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
