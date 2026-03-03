# 代码文件组织治理与组件归位 - Compose 到 SwiftUI 迁移总结

## 1. 本次 iOS 知识点
- 组件归位应基于“真实复用”而不是“潜在复用”：
  - 仅单 Feature 使用的组件，应放 `xmnote/Views/<Feature>/Components/`。
  - 真正跨模块复用的组件，才进入 `xmnote/UIComponents/`。
- `Sheet`、页面壳层、页面私有子视图要严格分层，目录即架构边界：
  - 页面壳层：`xmnote/Views/<Feature>/`
  - 页面私有子视图：`xmnote/Views/<Feature>/Components/`
  - 业务弹层：`xmnote/Views/<Feature>/Sheets/`
- 目录治理必须脚本化守护，靠约定不够：
  - 本次通过 `scripts/verify_view_component_boundaries.sh` 增加“Feature 私有组件误入 UIComponents”拦截规则，降低回归风险。
- 应用级全局状态（如 `AppState`）建议收拢到 `xmnote/AppState/`，避免散落在仓库根目录，提升可发现性与可维护性。

## 2. Android Compose 对照思路
- Compose 项目里常见分层：
  - `feature/<name>/ui/components` 对应 iOS 的 `Views/<Feature>/Components`
  - `core/designsystem` 或 `core/ui` 对应 iOS 的 `UIComponents`
- 迁移原则一致：
  - “先本地私有，后提炼公共”
  - 当第二个 Feature 出现真实复用，再抽到公共层。
- 建议把“组件晋升规则”写成团队规范并配 CI 校验，避免公共层膨胀。

## 3. 可运行对照示例
### 3.1 Android Compose（Feature 私有组件）
```kotlin
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

// feature/reading/ui/components/CalendarMonthStepperBar.kt
@Composable
fun CalendarMonthStepperBar(
    title: String,
    onClickMonth: () -> Unit
) {
    Row(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(text = title)
        // 点击逻辑省略：可接 DropdownMenu
    }
}
```

### 3.2 SwiftUI（Feature 私有组件）
```swift
import SwiftUI

// Views/Reading/ReadCalendar/Components/CalendarMonthStepperBar.swift
struct CalendarMonthStepperBar: View {
    let title: String
    let onSelectMonth: () -> Void

    var body: some View {
        Button(action: onSelectMonth) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
    }
}
```

## 4. 组件晋升（私有 -> 公共）判定清单
- 至少两个 Feature 有真实复用需求。
- 组件不依赖业务状态、不访问 Repository/Database/Network。
- API 可稳定抽象（输入参数清晰，副作用可控）。
- 晋升后同步完成：术语表、组件文档清单、边界脚本。

## 5. 迁移结论
- 好的文件组织不是“美观问题”，而是“维护成本与错误率问题”。
- 目录边界越清晰，团队越容易在重构中保持速度和质量。
- 先严格私有化，再谨慎公共化，是 Android Compose 与 SwiftUI 都成立的长期策略。
