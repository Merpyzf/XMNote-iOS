# 热力图打卡语义对齐总结（Android Compose → SwiftUI）

## 1. 本次 iOS 关键知识点

- **领域模型要承载“业务口径”而非仅 UI 口径**
  本次问题根因是 `HeatmapDay.level` 只看 `readSeconds` 与 `noteCount`，忽略了新增的打卡活动。修复后在 `HeatmapDay` 中新增 `checkInSeconds`，让模型本身能表达“打卡参与强度计算”的业务事实。

- **Repository 聚合与渲染等级必须同源**
  仅在 Repository 层把“有打卡”日期塞进结果还不够；等级函数若不消费打卡值，会出现“有数据但等级为 none”的语义断裂。

- **打卡口径对齐 Android：amount × 20 分钟**
  iOS 端从 `COUNT(*)` 升级为“次数 + 时长”双聚合，时长按 `SUM(amount * 1200)`（秒）计算，和 Android 的 `checkInTime += amount * (20 * 60)` 保持一致。

- **无障碍文案应与视觉状态一致**
  热力图读屏文本新增打卡信息（`打卡X次`），避免“颜色有活动但语音说无活动”或“有打卡却被当作无活动”。

## 2. Android Compose 对照思路

| 维度 | Android | iOS | 对齐策略 |
|---|---|---|---|
| 日模型 | `Mark(readTime/noteCount/checkInTime)` | `HeatmapDay(readSeconds/noteCount/checkInCount/checkInSeconds)` | iOS 增加 `checkInSeconds`，承载打卡强度语义 |
| 打卡聚合 | `checkInTime += amount * 20min` | SQL `SUM(amount * 1200)` | 统一“打卡时长”口径 |
| 综合等级 | `max(note, read, checkIn)` | `max(note, read, checkInSeconds)` | 统一最大值决策 |
| 读屏文案 | 由业务层拼装活动信息 | `HeatmapChart.accessibilityText(...)` | 文案包含打卡次数与综合等级 |

## 3. 可运行示例（最小骨架）

### 3.1 SwiftUI（iOS 端）

```swift
import Foundation

enum HeatLevel: Int {
    case none, veryLess, less, more, veryMore

    static func fromReadSeconds(_ value: Int) -> HeatLevel {
        switch value {
        case 0: .none
        case 1...1200: .veryLess
        case 1201...2400: .less
        case 2401...3600: .more
        default: .veryMore
        }
    }

    static func fromNoteCount(_ value: Int) -> HeatLevel {
        switch value {
        case 0: .none
        case 1...5: .veryLess
        case 6...10: .less
        case 11...20: .more
        default: .veryMore
        }
    }
}

struct HeatDay {
    let readSeconds: Int
    let noteCount: Int
    let checkInCount: Int
    let checkInSeconds: Int

    var level: HeatLevel {
        let readLevel = HeatLevel.fromReadSeconds(readSeconds)
        let noteLevel = HeatLevel.fromNoteCount(noteCount)
        let checkInLevel = HeatLevel.fromReadSeconds(checkInSeconds)
        let raw = max(max(readLevel.rawValue, noteLevel.rawValue), checkInLevel.rawValue)
        return HeatLevel(rawValue: raw) ?? .none
    }
}

let checkInOnly = HeatDay(readSeconds: 0, noteCount: 0, checkInCount: 1, checkInSeconds: 1200)
print(checkInOnly.level) // veryLess
```

### 3.2 Compose（Android 侧对照）

```kotlin
data class Mark(
    val readTime: Int,
    val noteCount: Int,
    val checkInTime: Int
)

object Level {
    const val NONE = 0
    const val VERY_LESS = 1
    const val LESS = 2
    const val MORE = 3
    const val VERY_MORE = 4
}

fun levelFromReadSeconds(value: Int): Int = when {
    value == 0 -> Level.NONE
    value <= 1200 -> Level.VERY_LESS
    value <= 2400 -> Level.LESS
    value <= 3600 -> Level.MORE
    else -> Level.VERY_MORE
}

fun levelFromNoteCount(value: Int): Int = when {
    value == 0 -> Level.NONE
    value <= 5 -> Level.VERY_LESS
    value <= 10 -> Level.LESS
    value <= 20 -> Level.MORE
    else -> Level.VERY_MORE
}

fun mergedLevel(mark: Mark): Int {
    val note = levelFromNoteCount(mark.noteCount)
    val read = levelFromReadSeconds(mark.readTime)
    val checkIn = levelFromReadSeconds(mark.checkInTime)
    return maxOf(note, read, checkIn)
}
```

## 4. 迁移经验

- 迁移时不要只对齐“字段名”，要对齐“字段背后的计量口径”。
- 数据过滤、等级计算、无障碍文案必须共享同一事实源。
- 如果 Android 已有稳定业务语义（如 `amount*20min`），iOS 应优先做语义对齐，再做平台表达优化。
