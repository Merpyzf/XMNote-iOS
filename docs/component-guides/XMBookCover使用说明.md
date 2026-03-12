# XMBookCover 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMBookCover.swift`
- 角色：统一书籍封面渲染组件，负责宽高比、裁切、占位图、边框与轻量厚度边语义。
- 边界：组件只负责封面表面渲染，不内置业务阴影、导航点击和进度文案；进度表达统一由 `BookCoverProgressBar` 叠加。

## 快速接入
```swift
XMBookCover.fixedWidth(
    80,
    urlString: book.cover,
    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
)
```

## 参数说明
### 核心初始化参数
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `urlString` | `String` | 无 | 书籍封面 URL；空串或纯空白时自动走占位图。 |
| `width` | `CGFloat?` | `nil` | 固定宽度；与 `height` 组合决定最终尺寸策略。 |
| `height` | `CGFloat?` | `nil` | 固定高度；与 `width` 组合决定最终尺寸策略。 |
| `cornerRadius` | `CGFloat` | `CornerRadius.inlaySmall` | 封面统一圆角。 |
| `cornerRadii` | `RectangleCornerRadii?` | `nil` | 需要不等角时覆盖统一圆角。 |
| `border` | `XMBookCover.Border?` | `nil` | 封面边框配置。 |
| `placeholderBackground` | `Color` | `.bookCoverPlaceholderBackground` | 占位底色。 |
| `placeholderIconSize` | `XMBookCover.PlaceholderIconSize` | `.large` | 占位图标档位。 |
| `priority` | `XMImageRequestBuilder.Priority` | `.normal` | 图片请求优先级。 |
| `surfaceStyle` | `XMBookCover.SurfaceStyle` | `.plain` | 封面表面样式（平面/厚度边）。 |

### 尺寸工厂
| 工厂方法 | 适用场景 | 说明 |
| --- | --- | --- |
| `responsive(...)` | 宽度由父容器控制 | 组件自行按 `aspectRatio = 0.7` 推导高度。 |
| `fixedWidth(...)` | 书库网格、列表卡片 | 只传宽度，高度自动推导。 |
| `fixedHeight(...)` | 按高度对齐的横向卡片 | 只传高度，宽度自动推导。 |
| `fixedSize(...)` | 阅读日历堆叠、转场源位 | 宽高由外部精确指定。 |

### 关键枚举
| 类型 | 可选值 | 说明 |
| --- | --- | --- |
| `SurfaceStyle` | `.plain` / `.spine` | `.plain` 保持平面封面；`.spine` 在满足尺寸阈值时补轻量厚度边。 |
| `PlaceholderIconSize` | `.large` / `.medium` / `.small` / `.hidden` | 统一控制占位图标密度；`.hidden` 只保留底色。 |

## 示例
### 示例 1：书库网格封面
```swift
XMBookCover.fixedWidth(
    110,
    urlString: book.cover,
    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
)
```

### 示例 2：响应式封面
```swift
XMBookCover.responsive(
    urlString: detail.cover,
    placeholderIconSize: .medium,
    surfaceStyle: .spine
)
```

### 示例 3：阅读日历固定尺寸封面
```swift
XMBookCover.fixedSize(
    width: 54,
    height: 77,
    urlString: book.cover,
    placeholderIconSize: .small,
    surfaceStyle: .spine
)
```

## 常见问题
### 1) 什么时候选 `fixedWidth`，什么时候选 `fixedSize`？
大多数列表和网格只需要锁定宽度，优先用 `fixedWidth`。只有像阅读日历堆叠、转场源位这类宽高都必须精准对齐的场景才用 `fixedSize`。

### 2) 为什么阴影不内置？
封面在书库、排行榜、阅读日历里的阴影策略不同。`XMBookCover` 只统一表面语言与厚度边，场景阴影由外层决定，避免把单一阴影写死到所有业务里。

### 3) 为什么所有封面渲染必须统一走 `XMBookCover`？
项目要求统一宽高比、`.fill` Crop 裁切、占位图和边框语义；直接手写远程图 + 裁切组合会再次分叉出不同封面风格和比例。

### 4) `surfaceStyle = .spine` 一定会出现厚度边吗？
不会。组件会通过 `resolvedSurfaceTier(for:requestedStyle:)` 按实际尺寸判定；尺寸不足时会自动降级为平面封面，避免小尺寸出现脏边。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
