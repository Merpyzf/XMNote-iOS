# CalendarMonthStepperBar 使用说明

## 组件定位
`CalendarMonthStepperBar` 是月视图顶部的月份切换触发组件，提供：
- 中间月份标题展示。
- 点击标题打开月份菜单并快速跳月。
- 标题区仅保留文字与下拉箭头，不展示日历图标。
- 去容器化触发样式（无液态玻璃背景），减少顶部视觉噪音。

源码路径：`xmnote/UIComponents/Foundation/CalendarMonthStepperBar.swift`

## 快速接入
```swift
CalendarMonthStepperBar(
    title: viewModel.monthTitle,
    availableMonths: viewModel.availableMonths,
    selectedMonth: viewModel.pagerSelection,
    onSelectMonth: { month in
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.pagerSelection = month
        }
    }
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `title` | `String` | 无 | 中央月份标题（建议 `yyyy年M月`）。 |
| `availableMonths` | `[Date]` | 无 | 可选择的月份列表（建议升序）。 |
| `selectedMonth` | `Date` | 无 | 当前选中月份（用于菜单勾选）。 |
| `onSelectMonth` | `(Date) -> Void` | 无 | 选择某个月份后的回调。 |

## 示例

### 示例 1：阅读日历页接入
```swift
CalendarMonthStepperBar(
    title: panelProps.monthTitle,
    availableMonths: panelProps.availableMonths,
    selectedMonth: panelProps.pagerSelection,
    onSelectMonth: onPagerSelectionChanged
)
```

### 示例 2：仅允许历史月份
```swift
CalendarMonthStepperBar(
    title: monthTitle,
    availableMonths: historyMonths,
    selectedMonth: pagerSelection,
    onSelectMonth: onSelectMonth
)
```

## 设计建议
- 将菜单触发区收敛到标题本身，减少顶部控制噪音。
- 跳月写回单一状态 `pagerSelection`，避免多入口状态分叉。
- 标题文案建议使用 `.contentTransition(.numericText())` 保持数字切换质感。
- 在顶部双控件布局中建议放在左侧并保持较高 `layoutPriority`，避免被右侧模式控件挤压。

## 常见问题

### 1) 为什么不再保留左右箭头？
本组件目标是“快速跳月”，在有菜单直达的前提下，箭头会增加视觉负担且与分页滑动功能重叠。

### 2) 菜单顺序为什么是从新到旧？
组件内部默认逆序展示（最近月份在上方），降低常用月份的点击成本。

### 3) 快速跳月会不会影响左右滑动分页？
不会。两种交互最终都只更新同一个 `pagerSelection`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
