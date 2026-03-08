# XMJXImageWall 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/GalleryJX/XMJXImageWall.swift`
- 角色：基于 `JXPhotoBrowser` 的 SwiftUI 图片墙组件，负责宫格布局、点击命中与全屏浏览触发。
- 典型场景：书摘图片组、笔记附件九宫格、调试图库墙。

## 快速接入
```swift
let items: [XMJXGalleryItem] = imageURLs.enumerated().map { index, url in
    XMJXGalleryItem(
        id: "img_\(index)",
        thumbnailURL: url,
        originalURL: url
    )
}

XMJXImageWall(items: items)
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `items` | `[XMJXGalleryItem]` | 无 | 图片墙数据源，需保证 `id` 稳定唯一。 |
| `columnCount` | `Int` | `3` | 列数，内部会自动限制最小为 `1`。 |
| `spacing` | `CGFloat` | `6` | 宫格间距。 |

## 示例
### 示例 1：标准 3 列图片墙
```swift
XMJXImageWall(items: galleryItems)
    .padding(.horizontal, Spacing.screenEdge)
```

### 示例 2：2 列大图墙
```swift
XMJXImageWall(
    items: galleryItems,
    columnCount: 2,
    spacing: 10
)
```

## 常见问题
### 1) 点击缩略图没有反应
先确认 `items` 不为空，且 `XMJXGalleryItem.id` 唯一；重复 ID 会导致缩略图注册表映射被覆盖。

### 2) 全屏转场时起始位置不准确
确认不要在 `XMJXImageWall` 外层再额外包裹会改变命中区域的透明手势层；组件内部已使用 `contentShape(Rectangle())` 和 `SpatialTapGesture`。

### 3) 动态更新数据后打开了旧图片
更新数据时应整体替换 `items`，不要仅改 URL 但复用同一条目的无效 ID。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
