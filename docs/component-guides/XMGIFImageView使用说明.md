# XMGIFImageView 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMGIFImageView.swift`
- 角色：SwiftUI 与 Gifu 的桥接层，负责 GIF 数据播放与生命周期回收。
- 使用建议：通常由 `XMRemoteImage` 间接调用；仅在你已持有 GIF 二进制数据时直接使用。

## 快速接入
```swift
XMGIFImageView(
    data: gifData,
    contentMode: .fill,
    autoplay: true
)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `data` | `Data` | 无 | GIF 原始数据。 |
| `contentMode` | `ContentMode` | 无 | `fit/fill` 映射到 UIKit `scaleAspectFit/scaleAspectFill`。 |
| `autoplay` | `Bool` | 无 | 是否自动播放。 |

## 示例
### 示例 1：在卡片中播放 GIF
```swift
XMGIFImageView(data: gifData, contentMode: .fill, autoplay: true)
    .frame(width: 80, height: 112)
    .clipShape(RoundedRectangle(cornerRadius: 8))
```

### 示例 2：按交互控制播放
```swift
XMGIFImageView(
    data: gifData,
    contentMode: .fit,
    autoplay: isVisible
)
```

## 常见问题
### 1) 为什么推荐优先用 `XMRemoteImage`？
`XMRemoteImage` 已包含 URL 合法性校验、请求构造、GIF 探测和失败降级；`XMGIFImageView` 只负责“播放”。

### 2) 会不会重复启动动画？
组件内部通过 `Coordinator.lastData` 防止同一数据重复 `animate(withGIFData:)`。

### 3) 视图销毁后会不会泄漏？
`dismantleUIView` 会调用 `prepareForReuse()` 并清空缓存引用，用于回收播放状态。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
