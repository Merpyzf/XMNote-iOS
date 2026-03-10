# Timeline/
> L2 | 父级: Reading/CLAUDE.md

在读模块时间线子功能视图层，承载正式页面壳层与页面私有时间线卡片组件。对应 ViewModel 位于 `xmnote/ViewModels/Reading/TimelineViewModel.swift`。

## 成员清单

- `ReadingTimelineView.swift`: 时间线正式页面壳层（日历切月、日期选择、分类过滤、按日列表与粘性头）
- `Components/TimelineEventRow.swift`: 页面私有时间线事件分发组件（含 `TimelineSectionHeader` 与 `TimelineSectionView`）
- `Components/TimelineNoteCard.swift`: 页面私有书摘卡片组件
- `Components/TimelineTimingCard.swift`: 页面私有阅读计时卡片组件
- `Components/TimelineStatusCard.swift`: 页面私有阅读状态卡片组件
- `Components/TimelineCheckInCard.swift`: 页面私有打卡卡片组件
- `Components/TimelineReviewCard.swift`: 页面私有书评卡片组件
- `Components/TimelineRelevantCard.swift`: 页面私有相关内容卡片组件
- `Components/TimelineRelevantBookCard.swift`: 页面私有相关书籍卡片组件

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
