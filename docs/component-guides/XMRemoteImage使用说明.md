# XMRemoteImage 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMRemoteImage.swift`
- 角色：统一远程图片加载组件，封装 Nuke/NukeUI 请求、占位、GIF 识别与降级策略。
- 典型场景：书籍封面、详情头图、排行封面、小组件图像位。

## 快速接入
```swift
XMRemoteImage(urlString: book.cover, showsGIFBadge: true) {
    RoundedRectangle(cornerRadius: 6)
        .fill(Color.tagBackground)
}
```

## 参数说明
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `urlString` | `String` | 无 | 图片 URL（仅支持 `http/https`）。 |
| `contentMode` | `ContentMode` | `.fill` | 图片填充方式。 |
| `priority` | `XMImageRequestBuilder.Priority` | `.normal` | 请求优先级（`low/normal/high`）。 |
| `showsGIFBadge` | `Bool` | `false` | 是否显示 `GIF` 角标。 |
| `pipeline` | `ImagePipeline` | `.shared` | 可注入自定义 Nuke 管线（测试/隔离场景）。 |
| `placeholder` | `() -> Placeholder` | 无 | 占位视图构造器。 |

## 示例
### 示例 1：书籍网格封面
```swift
XMRemoteImage(urlString: book.cover) {
    Color.tagBackground.overlay {
        Image(systemName: "book.closed")
    }
}
.aspectRatio(0.68, contentMode: .fit)
```

### 示例 2：高优先级首屏图
```swift
XMRemoteImage(
    urlString: heroURL,
    contentMode: .fit,
    priority: .high,
    showsGIFBadge: false
) {
    ProgressView()
}
```

## 常见问题
### 1) URL 非法会怎样？
组件会直接显示 `placeholder`，不会触发网络请求。

### 2) 如何处理“伪装 GIF”（URL 后缀不是 `.gif`）？
组件会先按静态图加载，再在响应头/二进制探测到 GIF 后切换到 GIF 播放路径。

### 3) 失败后是否会崩溃或空白？
不会。失败统一回退到占位视图，GIF 加载失败会降级为静态图尝试。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
