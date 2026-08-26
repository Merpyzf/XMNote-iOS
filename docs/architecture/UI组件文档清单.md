# UI 组件文档清单

说明
- 该清单用于 `scripts/verify_component_guides.sh` 校验。
- `scripts/design-system/component-catalog.json` 是 `xmnote/UIComponents` 的完整机器可读清单；本表登记其中需要独立指南的公共组件，以及 UI 核心白名单页面。
- 页面私有组件即使保留历史使用指南，也不因文档存在而成为公共组件。

| 组件名 | 重要级别 | 源码路径 | 使用文档路径 | 触发条件 |
| --- | --- | --- | --- | --- |
| HeatmapChart | UI-复用关键 | xmnote/UIComponents/Charts/HeatmapChart.swift | docs/component-guides/HeatmapChart使用说明.md | 新增/重大重构 |
| ReadingDurationRankingChart | UI-复用关键 | xmnote/UIComponents/Charts/ReadingDurationRankingChart.swift | docs/component-guides/ReadingDurationRankingChart使用说明.md | 新增/重大重构 |
| XMRemoteImage | UI-复用关键 | xmnote/UIComponents/Media/Images/XMRemoteImage.swift | docs/component-guides/XMRemoteImage使用说明.md | 新增/重大重构 |
| XMGIFImageView | UI-复用关键 | xmnote/UIComponents/Media/Images/XMGIFImageView.swift | docs/component-guides/XMGIFImageView使用说明.md | 新增/重大重构 |
| XMBookCover | UI-复用关键 | xmnote/UIComponents/Foundation/XMBookCover.swift | docs/component-guides/XMBookCover使用说明.md | 新增/重大重构 |
| XMActivityShareSheet | UI-复用关键 | xmnote/UIComponents/System/Sharing/XMActivityShareSheet.swift | docs/component-guides/XMActivityShareSheet使用说明.md | 新增/重大重构 |
| XMYearMonthPickerSheet | UI-复用关键 | xmnote/UIComponents/Sheet/XMYearMonthPickerSheet.swift | docs/component-guides/XMYearMonthPickerSheet使用说明.md | 新增/重大重构 |
| XMRatingBar | UI-复用关键 | xmnote/UIComponents/Controls/Rating/XMRatingBar.swift | docs/component-guides/XMRatingBar使用说明.md | 新增/重大重构 |
| XMBookRatingSheet | UI-复用关键 | xmnote/UIComponents/Business/Book/XMBookRatingSheet.swift | docs/component-guides/XMRatingBar使用说明.md | 新增/重大重构 |
| XMScopeSelector | UI-复用关键 | xmnote/UIComponents/Controls/Selection/XMScopeSelector.swift | docs/component-guides/XMScopeSelector使用说明.md | 新增/重大重构 |
| XMSearchHistorySection | UI-复用关键 | xmnote/UIComponents/Controls/Search/XMSearchHistorySection.swift | docs/component-guides/XMSearchHistorySection使用说明.md | 新增/重大重构 |
| XMScrollEdgeChrome | UI-复用关键 | xmnote/UIComponents/Navigation/ScrollEdge/XMScrollEdgeChrome.swift | docs/component-guides/XMScrollEdgeChrome使用说明.md | 新增/重大重构 |
| XMScrollEdgeWash | UI-复用关键 | xmnote/UIComponents/Navigation/ScrollEdge/XMScrollEdgeWash.swift | docs/component-guides/XMScrollEdgeChrome使用说明.md | 新增/重大重构 |
| ExpandableRichText | UI-复用关键 | xmnote/UIComponents/Media/RichText/ExpandableRichText.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| RichText | UI-复用关键 | xmnote/UIComponents/Media/RichText/RichText.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| CollapsedRichTextPreview | UI-复用关键 | xmnote/UIComponents/Media/RichText/CollapsedRichTextPreview.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| XMToast | UI-复用关键 | xmnote/UIComponents/Feedback/Toast/XMToast.swift | docs/component-guides/XMToast使用说明.md | 新增/重大重构 |
| XMContentStateView | UI-复用关键 | xmnote/UIComponents/Feedback/StatePresentation/XMContentStateView.swift | docs/component-guides/XMStatePresentation使用说明.md | 新增/重大重构 |
| XMCompactStateView | UI-复用关键 | xmnote/UIComponents/Feedback/StatePresentation/XMCompactStateView.swift | docs/component-guides/XMStatePresentation使用说明.md | 新增/重大重构 |
| XMInlineStatusBanner | UI-复用关键 | xmnote/UIComponents/Feedback/StatePresentation/XMInlineStatusBanner.swift | docs/component-guides/XMStatePresentation使用说明.md | 新增/重大重构 |
| LoadingStateView | UI-复用关键 | xmnote/UIComponents/Feedback/LoadingStateView.swift | docs/component-guides/XMStatePresentation使用说明.md | 迁移/重大重构 |
| LoadPhaseHost | UI-复用关键 | xmnote/UIComponents/Feedback/Loading/LoadingFeedbackKit.swift | docs/component-guides/XMStatePresentation使用说明.md | 迁移/重大重构 |
| XMTagLabel | UI-复用关键 | xmnote/UIComponents/Business/Tag/XMTagLabel.swift | docs/component-guides/XMTagLabel使用说明.md | 新增/重大重构 |
| XMTagSelectionSheet | UI-复用关键 | xmnote/UIComponents/Business/Tag/XMTagSelectionSheet.swift | docs/component-guides/XMTagSelectionSheet使用说明.md | 新增/重大重构 |
| XMMinimumHitTarget | UI-基础设施关键 | xmnote/UIComponents/Controls/Button/XMMinimumHitTarget.swift | docs/component-guides/XMMinimumHitTarget使用说明.md | 新增/重大重构 |
| XMMinimumHitTargetButton | UI-基础设施关键 | xmnote/UIComponents/Controls/Button/XMMinimumHitTargetButton.swift | docs/component-guides/XMMinimumHitTarget使用说明.md | 新增/重大重构 |
| XMSettingsPage | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsPage.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsSection | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsSection.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsGroup | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsGroup.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsDivider | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsGroup.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsValueMenuRow | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsRows.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsToggleRow | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsRows.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSheetScaffold | UI-复用关键 | xmnote/UIComponents/Sheet/XMSheetScaffold.swift | docs/component-guides/XMSheetScaffold使用说明.md | 新增/重大重构 |
| TopSwitcher | UI-复用关键 | xmnote/UIComponents/Navigation/Tabs/TopSwitcher.swift | docs/component-guides/TopSwitcher使用说明.md | 新增/重大重构 |
| KeepAliveSwitcherHost | UI-复用关键 | xmnote/UIComponents/Navigation/Tabs/KeepAliveSwitcherHost.swift | docs/component-guides/KeepAliveSwitcherHost使用说明.md | 新增/重大重构 |
| HorizontalPagingHost | UI-复用关键 | xmnote/UIComponents/Navigation/Tabs/HorizontalPagingHost.swift | docs/component-guides/HorizontalPagingHost使用说明.md | 新增/重大重构 |
| XMJXImageWall | UI-复用关键 | xmnote/UIComponents/Media/GalleryJX/XMJXImageWall.swift | docs/component-guides/XMJXImageWall使用说明.md | 新增/重大重构 |
| XMJXThumbnailView | UI-复用关键 | xmnote/UIComponents/Media/GalleryJX/XMJXThumbnailView.swift | docs/component-guides/XMJXThumbnailView使用说明.md | 新增/重大重构 |
| BookContainerView | UI-核心页面关键 | xmnote/Views/Book/BookContainerView.swift | docs/component-guides/BookContainerView使用说明.md | 新增/重大重构 |
| BookGridView | UI-核心页面关键 | xmnote/Views/Book/BookGridView.swift | docs/component-guides/BookGridView使用说明.md | 新增/重大重构 |
| BookGridItemView | UI-核心页面关键 | xmnote/Views/Book/BookGridItemView.swift | docs/component-guides/BookGridItemView使用说明.md | 新增/重大重构 |
| BookDetailView | UI-核心页面关键 | xmnote/Views/Book/BookDetailView.swift | docs/component-guides/BookDetailView使用说明.md | 新增/重大重构 |
| ChapterManagerView | UI-核心页面关键 | xmnote/Views/Book/ChapterManagerView.swift | docs/component-guides/ChapterManagerView使用说明.md | 新增/重大重构 |
| BookCollectionListView | UI-核心页面关键 | xmnote/Views/Book/BookCollectionListView.swift | docs/component-guides/BookCollectionListView使用说明.md | 新增/重大重构 |
| BookCollectionDetailView | UI-核心页面关键 | xmnote/Views/Book/BookCollectionDetailView.swift | docs/component-guides/BookCollectionDetailView使用说明.md | 新增/重大重构 |
| BookCollectionCoverSearchSheet | UI-核心页面关键 | xmnote/Views/Book/Sheets/BookCollectionCoverSearchSheet.swift | docs/component-guides/BookCollectionCoverSearchSheet使用说明.md | 新增/重大重构 |
| NoteContainerView | UI-核心页面关键 | xmnote/Views/Note/NoteContainerView.swift | docs/component-guides/NoteContainerView使用说明.md | 新增/重大重构 |
| NoteCollectionView | UI-核心页面关键 | xmnote/Views/Note/NoteCollectionView.swift | docs/component-guides/NoteCollectionView使用说明.md | 新增/重大重构 |
| NoteTagsView | UI-核心页面关键 | xmnote/Views/Note/NoteTagsView.swift | docs/component-guides/NoteTagsView使用说明.md | 新增/重大重构 |
| NoteDetailView | UI-核心页面关键 | xmnote/Views/Note/NoteDetailView.swift | docs/component-guides/NoteDetailView使用说明.md | 新增/重大重构 |
| NoteReviewView | UI-核心页面关键 | xmnote/Views/Note/NoteReviewView.swift | docs/component-guides/NoteReviewView使用说明.md | 新增/重大重构 |
| DataBackupView | UI-核心页面关键 | xmnote/Views/Personal/Backup/DataBackupView.swift | docs/component-guides/DataBackupView使用说明.md | 新增/重大重构 |
| WebDAVServerListView | UI-核心页面关键 | xmnote/Views/Personal/Backup/WebDAVServerListView.swift | docs/component-guides/WebDAVServerListView使用说明.md | 新增/重大重构 |
| WebDAVServerFormView | UI-核心页面关键 | xmnote/Views/Personal/Backup/WebDAVServerFormView.swift | docs/component-guides/WebDAVServerFormView使用说明.md | 新增/重大重构 |
| BackupHistorySheetView | UI-核心页面关键 | xmnote/Views/Personal/Backup/Sheets/BackupHistorySheetView.swift | docs/component-guides/BackupHistorySheetView使用说明.md | 新增/重大重构 |
| ReadingContainerView | UI-核心页面关键 | xmnote/Views/Reading/ReadingContainerView.swift | docs/component-guides/ReadingContainerView使用说明.md | 新增/重大重构 |
| ReadingDashboardView | UI-核心页面关键 | xmnote/Views/Reading/ReadingDashboardView.swift | docs/component-guides/ReadingDashboardView使用说明.md | 新增/重大重构 |
| ReadingHeatmapWidgetView | UI-核心页面关键 | xmnote/Views/Reading/ReadingHeatmapWidgetView.swift | docs/component-guides/ReadingHeatmapWidgetView使用说明.md | 新增/重大重构 |
| ReadCalendarView | UI-核心页面关键 | xmnote/Views/Reading/ReadCalendar/ReadCalendarView.swift | docs/component-guides/ReadCalendar使用说明.md | 新增/重大重构 |
| ReadingTimelineView | UI-核心页面关键 | xmnote/Views/Reading/Timeline/ReadingTimelineView.swift | docs/component-guides/ReadingTimelineView使用说明.md | 新增/重大重构 |
| PersonalView | UI-核心页面关键 | xmnote/Views/Personal/PersonalView.swift | docs/component-guides/PersonalView使用说明.md | 新增/重大重构 |
| BookGroupManagementView | UI-核心页面关键 | xmnote/Views/Personal/BookGroupManagementView.swift | docs/component-guides/BookGroupManagementView使用说明.md | 新增/重大重构 |
| SourceManagementView | UI-核心页面关键 | xmnote/Views/Personal/SourceManagementView.swift | docs/component-guides/SourceManagementView使用说明.md | 新增/重大重构 |

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
