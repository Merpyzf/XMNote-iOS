# BookCoverProgressBar 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/BookCoverProgressBar.swift`
- 角色：覆盖在 `XMBookCover` 上的封面底部悬浮阅读进度条组件。
- 边界：组件只负责进度可视化，不负责业务状态文案、点击交互或通用进度条语义。

## 快速接入
```swift
XMBookCover.fixedWidth(110, urlString: book.cover)
    .overlay {
        BookCoverProgressBar(progress: 0.62)
    }
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `progress` | `Double` | 无 | 阅读进度值；组件内部会自动 clamp 到 `0...1`。 |

## 示例
### 示例 1：封面底部显示阅读进度
```swift
XMBookCover.fixedWidth(
    80,
    urlString: book.cover,
    surfaceStyle: .spine
)
.overlay {
    BookCoverProgressBar(progress: book.readProgress)
}
```

### 示例 2：有进度时才叠加
```swift
XMBookCover.responsive(urlString: book.cover)
    .overlay {
        if book.readProgress > 0 {
            BookCoverProgressBar(progress: book.readProgress)
        }
    }
```

## 常见问题
### 1) 如果传入 `-0.5` 或 `1.8` 会怎样？
组件会先把 `progress` 压到 `0...1` 范围，再计算填充宽度，不会溢出或产生负宽度。

### 2) 为什么它不能脱离封面当通用 `ProgressView` 使用？
这个组件的内边距、高度、玻璃材质和视觉比例都按封面尺寸推导，只适合作为封面覆盖层，不适合列表行或页面级进度展示。

### 3) 为什么它不响应点击也不参与无障碍？
它是纯装饰性状态层，业务交互应由封面卡片本身承担；因此组件固定 `allowsHitTesting(false)` 且 `accessibilityHidden(true)`，避免抢占交互语义。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
