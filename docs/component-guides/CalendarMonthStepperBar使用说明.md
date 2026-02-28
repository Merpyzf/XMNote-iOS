# CalendarMonthStepperBar 使用说明

## 组件定位
`CalendarMonthStepperBar` 是月视图顶部的月份切换胶囊组件，提供：
- 左右月份切换按钮（含禁用态）
- 中间月份标题展示
- 统一的轻量边框与胶囊背景样式

源码路径：`xmnote/UIComponents/Foundation/CalendarMonthStepperBar.swift`

## 快速接入
```swift
CalendarMonthStepperBar(
    title: viewModel.monthTitle,
    canGoPrev: viewModel.canGoPrevMonth,
    canGoNext: viewModel.canGoNextMonth,
    onPrev: {
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.stepPager(offset: -1)
        }
    },
    onNext: {
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.stepPager(offset: 1)
        }
    }
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `title` | `String` | 无 | 中央月份标题（建议 `yyyy年M月`） |
| `canGoPrev` | `Bool` | 无 | 是否允许切到上月 |
| `canGoNext` | `Bool` | 无 | 是否允许切到下月 |
| `onPrev` | `() -> Void` | 无 | 点击左箭头回调 |
| `onNext` | `() -> Void` | 无 | 点击右箭头回调 |

## 示例

### 示例 1：阅读日历页接入
```swift
CalendarMonthStepperBar(
    title: viewModel.monthTitle,
    canGoPrev: viewModel.canGoPrevMonth,
    canGoNext: viewModel.canGoNextMonth,
    onPrev: {
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.stepPager(offset: -1)
        }
    },
    onNext: {
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.stepPager(offset: 1)
        }
    }
)
```

## 设计建议
- 推荐将切月行为放在 `withAnimation(.snappy)` 中调用，保持手感统一。
- 建议放在日历容器上方使用，并与下方日历主体保持明确层级。
- 当页面有系统返回按钮时，保持月份箭头为控件风格，避免与系统导航箭头语义冲突。

## 常见问题

### 1) 为什么禁用态箭头仍可见？
这是有意设计。禁用态保留可见图标可以表达“方向存在但当前不可达”，避免布局跳动。

### 2) 标题切换时如何数字平滑过渡？
组件内部已使用 `.contentTransition(.numericText())`，调用方只需保证状态更新在动画上下文中。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
