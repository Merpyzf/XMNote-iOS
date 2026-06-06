# XMRatingBar 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMRatingBar.swift`
- 角色：统一书籍评分展示与评分输入组件，对齐 Android `FluentRatingBar` 的圆润星形与半星/整星步进语义。
- 边界：组件只负责评分星形、步进、触摸写回和无障碍调整；不负责业务保存、表单校验、提示文案或评分来源转换之外的业务解释。

## 快速接入
```swift
XMRatingBar(
    score: book.score,
    preset: .listSmall
)
```

## 参数说明
### 展示初始化
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `value` | `Double` | 无 | 只读评分值，范围按 `0...starCount` 归一化。 |
| `score` | `Int64` | 无 | Android/iOS 业务分数，范围为 `0...50`，组件内部按 `/10` 转成星级。 |
| `starCount` | `Int` | `5` | 星星数量，小于 1 时会被组件修正为 1。 |
| `preset` | `XMRatingBarPreset` | `.listSmall` | 评分条尺寸预设。 |
| `step` | `XMRatingBarStep` | `.half` | 只读填充粒度，通常保持半星。 |
| `activeColor` | `Color` | `.ratingActive` | 已评分星形颜色。 |
| `inactiveColor` | `Color` | `.ratingInactive` | 未评分星形颜色。 |

### 交互初始化
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `value` | `Binding<Double>` | 无 | 可交互评分绑定值，拖动、点击和无障碍增减都会写回。 |
| `isIndicator` | `Bool` | `false` | 为 `true` 时禁用触摸手势，作为只读指示器渲染。 |
| `onValueChange` | `(Double) -> Void` | 空闭包 | 拖动过程中值变化时触发，适合做即时预览。 |
| `onRatingChanged` | `(Double) -> Void` | 空闭包 | 手势结束或无障碍调整确认时触发，适合提交业务写入。 |

### 关键枚举
| 类型 | 可选值 | 说明 |
| --- | --- | --- |
| `XMRatingBarStep` | `.one` / `.half` | 整星或半星步进。 |
| `XMRatingBarPreset` | `.listSmall` / `.capsule` / `.form` / `.dialog` | 分别用于列表、胶囊信息位、表单与中心弹窗。 |

## 示例
### 示例 1：列表只读评分
```swift
XMRatingBar(
    score: book.score,
    preset: .listSmall
)
```

### 示例 2：表单内交互评分
```swift
XMRatingBar(
    value: $draftRating,
    preset: .form,
    step: .half,
    onRatingChanged: { nextValue in
        viewModel.updateRating(nextValue)
    }
)
```

### 示例 3：弹窗大尺寸评分
```swift
XMRatingBar(
    value: $rating,
    preset: .dialog,
    step: .one
)
```

### 示例 4：自定义尺寸
```swift
XMRatingBar(
    value: $rating,
    size: 24,
    spacing: 4,
    step: .half
)
```

## 常见问题
### 1) `score` 和 `value` 应该选哪个？
展示数据库或 Android 对齐字段时优先用 `score`，因为业务分数是 `0...50`；表单交互和临时草稿优先用 `Binding<Double>` 的 `value`。

### 2) `onValueChange` 和 `onRatingChanged` 有什么区别？
`onValueChange` 会在拖动过程中多次触发，只适合更新本地预览；`onRatingChanged` 在交互结束或无障碍调整确认后触发，适合交给 ViewModel 执行业务提交。

### 3) 为什么交互态高度可能大于星星视觉高度？
交互态会把触摸高度提升到至少 44pt，满足 iOS 可点击热区要求；只读态则保持星星视觉高度，避免列表行被撑高。

### 4) 组件会自动限制异常值吗？
会。`value` 会被限制在 `0...starCount`，`starCount` 至少为 1；拖动位置也会被限制在组件宽度范围内。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
