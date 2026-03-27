# 书摘编辑聚焦模式与元数据行收敛（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点

- 聚焦输入场景里，“内容区高度”不能只看编辑器本身，必须把固定区（书籍卡片、元数据、工具栏、附件）从可用视口里扣掉。
- 首帧测量不稳定是 SwiftUI 常见问题，实战里要区分：
  - 实时测量值（会抖动）；
  - 稳定测量值（可用于主分配决策）。
- 元数据行如果重复手写，很容易出现“章节改了、标签忘了、创建时间又偏了”的补丁式回归。
- 字体治理要按角色分层，而不是按页面散点调字号：
  - 输入正文；
  - 元数据标题；
  - 元数据值。

## 2. Compose -> SwiftUI 思维对照

| 目标 | Android 侧常见实现 | SwiftUI 本次实现 | 迁移原则 |
| --- | --- | --- | --- |
| 聚焦摘录高度分配 | `availableContainer - fixedElements` 动态计算 | `makeEditorHeightComputation` 单入口计算对象化输出 | 先统一模型，再落 UI |
| 想法收起状态 | `noteIdeaContainer=48dp` + 内容区重算 | `ideaState == .collapsed` 分支统一计算 | 业务状态先行于布局细节 |
| 元数据区多行交互 | `RelativeLayout/LinearLayout` 分行拼装 | `metadataActionRow` 统一构建 | 重复结构必须抽象 |
| 调试日志 | 调试代码容易混进业务分支 | `observeEditorTextChange` 统一 Debug 代理 | 调试入口与业务入口分离 |
| 字体一致性 | 以 `sub_medium_text` 为主 | `AppTypography` 分层 token | 字号问题本质是语义问题 |

## 3. 关键实现经验

1. 高度计算要输出“分支标签 + 输入快照 + 结果”，这样你能知道当前为何进入该分支，而不是只看到结果高度。
2. 元数据行的“右侧附件槽位”必须 token 化（例如固定宽度），否则箭头/清空按钮/空态文本会在不同状态错位。
3. 空态文案要参与布局系统，不要额外绝对定位；正确做法是放进值区并用 `maxWidth + trailing` 对齐。

## 4. SwiftUI 可运行示例（行式元数据统一构建）

```swift
import SwiftUI

struct MetadataRowDemo: View {
    let title: String
    let value: String
    let isEmpty: Bool

    private let rowHeight: CGFloat = 54
    private let accessoryWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 12)
            Text(isEmpty ? "添加\(title)" : value)
                .foregroundStyle(isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: accessoryWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }
}
```

## 5. Compose 对照示例（同一行模型）

```kotlin
@Composable
fun MetadataRow(
    title: String,
    value: String?,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(54.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        Text(
            text = value ?: "添加$title",
            textAlign = TextAlign.End,
            color = if (value == null) Color.Gray else Color.Unspecified
        )
        Spacer(Modifier.width(8.dp))
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            modifier = Modifier.size(12.dp)
        )
    }
}
```

## 6. 迁移结论

- 这类页面的核心不是“某个控件高度”，而是“状态驱动的可用空间分配模型”。
- 当你发现自己在同一块区域不断修 margin/padding 时，通常不是细节没调好，而是缺了统一构建器或 token。
- Android -> iOS 对齐时，先对齐业务意图（先摘录、再补想法、元数据次级），再做平台表达，不做机械像素复刻。
