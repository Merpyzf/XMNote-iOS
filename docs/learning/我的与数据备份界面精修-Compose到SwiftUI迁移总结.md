# 我的与数据备份界面精修（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 设置页“精致感”往往来自节奏控制，而不是颜色堆叠；优先修 `rowMinHeight` 与分组间距，再谈装饰。
- `Menu` 触发范围要谨慎：把触发面缩到右侧值区可以显著减少整行布局抖动。
- 空字段处理要区分“信息缺失”和“状态缺失”：WebDAV 用“未配置”兜底，阿里云登录态由授权行承接，避免重复提示。
- 顶部操作按钮的“图标大小一致”不等于“容器大小一致”；必须统一容器尺寸。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose/传统 View 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 设置行点击热区 | `Modifier.heightIn(min = 48.dp)` 或 item padding | `frame(minHeight: 44)` | 先保热区，再做视觉压缩 |
| 行内图标权重 | `Icon(tint = onSurfaceVariant)` | 图标与主文本同色（`textPrimary`） | 设置页图标从属于信息，不抢主层级 |
| 备份方式切换 | 整行可点 + PopupMenu | 右侧值区 `Menu` | 可变信息动，标题不动 |
| 空字段兜底 | 文案 + 状态行混用 | `未配置` 与授权行分责 | 每个位置只表达一个语义 |
| 顶部双按钮一致性 | 固定 icon size | 统一容器 size | 用户感知的是容器节奏，不只是 glyph |

## 3. SwiftUI 可运行示例
```swift
import SwiftUI

struct SettingsRowDemo: View {
    @State private var provider = "WebDAV"

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云备份方式")
                    .font(.subheadline.weight(.medium))
                Text(provider == "WebDAV" ? "未配置" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("WebDAV") { provider = "WebDAV" }
                Button("阿里云盘") { provider = "阿里云盘" }
            } label: {
                HStack(spacing: 6) {
                    Text(provider)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(minWidth: 92, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }
}
```

## 4. Compose 对照示例
```kotlin
@Composable
fun BackupProviderRow(
    provider: String,
    onProviderSelected: (String) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("云备份方式", style = MaterialTheme.typography.bodyMedium)
            if (provider == "WebDAV") {
                Text("未配置", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(modifier = Modifier.weight(1f))
        // 仅右侧值区做菜单触发
        ProviderMenuAnchor(provider, onProviderSelected)
    }
}
```

## 5. 给 Android Compose 开发者的迁移提醒
- 不要只盯着 `dp` 数值，先确认“触控热区”和“视觉留白”是不是同一个参数在管。
- 当某个字段会频繁变化（如 provider、登录态）时，把可变区域从静态标题中剥离。
- 精修阶段优先做“减法”：去掉冗余状态、冗余图标、冗余分隔，通常比加动画更有效。
