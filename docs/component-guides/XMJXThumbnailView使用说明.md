# XMJXThumbnailView 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/GalleryJX/XMJXThumbnailView.swift`
- 角色：SwiftUI `UIViewRepresentable` 缩略图桥接组件，向 `JXPhotoBrowser` 提供可回溯的 `UIImageView` 缩略图来源。
- 典型场景：`XMJXImageWall` 内部缩略图渲染、需要 UIKit 级别缩略图注册的共享元素转场场景。

## 快速接入
```swift
let registry = XMJXThumbnailRegistry()

XMJXThumbnailView(
    item: item,
    registry: registry
)
.frame(width: 118, height: 118)
.clipped()
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `item` | `XMJXGalleryItem` | 无 | 缩略图与原图地址载体。 |
| `registry` | `XMJXThumbnailRegistry` | 无 | 缩略图注册表，需在同一墙面生命周期内复用同一个实例。 |
| `priority` | `XMImageRequestBuilder.Priority` | `.high` | 图片请求优先级。 |

## 示例
### 示例 1：在自定义网格中渲染缩略图
```swift
LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
    ForEach(items) { item in
        XMJXThumbnailView(item: item, registry: registry)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

### 示例 2：降低非首屏图优先级
```swift
XMJXThumbnailView(
    item: item,
    registry: registry,
    priority: .normal
)
```

## 常见问题
### 1) 为什么不建议每个 cell 都 new 一个 registry
`JXPhotoBrowser` 的缩略图定位依赖 `itemID -> UIImageView` 的统一映射，registry 分裂会导致转场源视图丢失。

### 2) 缩略图偶发空白
组件在 URL 无效时会直接返回占位空图，请优先校验 `thumbnailURL/originalURL` 是否是合法 `http/https`。

### 3) 复用时出现错图
确保 `XMJXGalleryItem.id` 稳定唯一，组件内部通过 `id` 做注册与解绑，ID 冲突会造成复用串图。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
