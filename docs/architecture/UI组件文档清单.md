# UI 组件文档清单

说明
- 该清单用于 `scripts/verify_component_guides.sh` 校验。
- 重要 UI 组件（UI 核心白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）必须登记。

| 组件名 | 重要级别 | 源码路径 | 使用文档路径 | 触发条件 |
| --- | --- | --- | --- | --- |
| HeatmapChart | UI-复用关键 | xmnote/UIComponents/Charts/HeatmapChart.swift | docs/component-guides/HeatmapChart使用说明.md | 新增/重大重构 |
| ReadingDurationRankingChart | UI-复用关键 | xmnote/UIComponents/Charts/ReadingDurationRankingChart.swift | docs/component-guides/ReadingDurationRankingChart使用说明.md | 新增/重大重构 |
| XMRemoteImage | UI-复用关键 | xmnote/UIComponents/Foundation/XMRemoteImage.swift | docs/component-guides/XMRemoteImage使用说明.md | 新增/重大重构 |
| XMGIFImageView | UI-复用关键 | xmnote/UIComponents/Foundation/XMGIFImageView.swift | docs/component-guides/XMGIFImageView使用说明.md | 新增/重大重构 |
| XMBookCover | UI-复用关键 | xmnote/UIComponents/Foundation/XMBookCover.swift | docs/component-guides/XMBookCover使用说明.md | 新增/重大重构 |
| XMBookGroupCover | UI-复用关键 | xmnote/UIComponents/Foundation/XMBookGroupCover.swift | docs/component-guides/XMBookGroupCover使用说明.md | 新增/重大重构 |
| XMActivityShareSheet | UI-复用关键 | xmnote/UIComponents/Foundation/XMActivityShareSheet.swift | docs/component-guides/XMActivityShareSheet使用说明.md | 新增/重大重构 |
| XMYearMonthPickerSheet | UI-复用关键 | xmnote/UIComponents/Foundation/XMYearMonthPickerSheet.swift | docs/component-guides/XMYearMonthPickerSheet使用说明.md | 新增/重大重构 |
| XMRatingBar | UI-复用关键 | xmnote/UIComponents/Foundation/XMRatingBar.swift | docs/component-guides/XMRatingBar使用说明.md | 新增/重大重构 |
| XMBookRatingSheet | UI-复用关键 | xmnote/UIComponents/Foundation/XMBookRatingSheet.swift | docs/component-guides/XMRatingBar使用说明.md | 新增/重大重构 |
| XMScopeSelector | UI-复用关键 | xmnote/UIComponents/Foundation/XMScopeSelector.swift | docs/component-guides/XMScopeSelector使用说明.md | 新增/重大重构 |
| XMSearchHistorySection | UI-复用关键 | xmnote/UIComponents/Foundation/XMSearchHistorySection.swift | docs/component-guides/XMSearchHistorySection使用说明.md | 新增/重大重构 |
| XMScrollEdgeChrome | UI-复用关键 | xmnote/UIComponents/Foundation/XMScrollEdgeChrome.swift | docs/component-guides/XMScrollEdgeChrome使用说明.md | 新增/重大重构 |
| XMScrollEdgeWash | UI-复用关键 | xmnote/UIComponents/Foundation/XMScrollEdgeWash.swift | docs/component-guides/XMScrollEdgeChrome使用说明.md | 新增/重大重构 |
| BookCoverProgressBar | UI-复用关键 | xmnote/UIComponents/Foundation/BookCoverProgressBar.swift | docs/component-guides/BookCoverProgressBar使用说明.md | 新增/重大重构 |
| ExpandableRichText | UI-复用关键 | xmnote/UIComponents/Foundation/ExpandableRichText.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| RichText | UI-复用关键 | xmnote/UIComponents/Foundation/RichText.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| CollapsedRichTextPreview | UI-复用关键 | xmnote/UIComponents/Foundation/CollapsedRichTextPreview.swift | docs/component-guides/ExpandableRichText使用说明.md | 新增/重大重构 |
| ImmersiveBottomChrome | UI-复用关键 | xmnote/UIComponents/Foundation/ImmersiveBottomChrome.swift | docs/component-guides/ImmersiveBottomChrome使用说明.md | 新增/重大重构 |
| XMToast | UI-复用关键 | xmnote/UIComponents/Foundation/XMToast.swift | docs/component-guides/XMToast使用说明.md | 新增/重大重构 |
| XMTagLabel | UI-复用关键 | xmnote/UIComponents/Foundation/XMTagLabel.swift | docs/component-guides/XMTagLabel使用说明.md | 新增/重大重构 |
| XMSettingsPage | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsPage.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsSection | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsSection.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsGroup | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsGroup.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsDivider | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsGroup.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsValueMenuRow | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsRows.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSettingsToggleRow | UI-复用关键 | xmnote/UIComponents/Settings/XMSettingsRows.swift | docs/component-guides/XMSettingsComponents使用说明.md | 新增/重大重构 |
| XMSheetScaffold | UI-复用关键 | xmnote/UIComponents/Sheet/XMSheetScaffold.swift | docs/component-guides/XMSheetScaffold使用说明.md | 新增/重大重构 |
| NoteReviewPagingDeck | UI-复用关键 | xmnote/UIComponents/Foundation/NoteReviewPaging/NoteReviewPagingDeck.swift | docs/component-guides/NoteReviewPagingDeck使用说明.md | 新增/重大重构 |
| TopSwitcher | UI-复用关键 | xmnote/UIComponents/Tabs/TopSwitcher.swift | docs/component-guides/TopSwitcher使用说明.md | 新增/重大重构 |
| XMInlineTabBar | UI-复用关键 | xmnote/UIComponents/Tabs/XMInlineTabBar.swift | docs/component-guides/XMInlineTabBar使用说明.md | 新增/重大重构 |
| KeepAliveSwitcherHost | UI-复用关键 | xmnote/UIComponents/Tabs/KeepAliveSwitcherHost.swift | docs/component-guides/KeepAliveSwitcherHost使用说明.md | 新增/重大重构 |
| HomeSubtabScaffold | UI-复用关键 | xmnote/UIComponents/Tabs/HomeSubtabScaffold.swift | docs/component-guides/HomeSubtabScaffold使用说明.md | 新增/重大重构 |
| HorizontalPagingHost | UI-复用关键 | xmnote/UIComponents/Tabs/HorizontalPagingHost.swift | docs/component-guides/HorizontalPagingHost使用说明.md | 新增/重大重构 |
| SubtabBootstrapCoordinator | UI-复用关键 | xmnote/UIComponents/Tabs/SubtabBootstrapCoordinator.swift | docs/component-guides/SubtabBootstrapCoordinator使用说明.md | 新增/重大重构 |
| XMJXImageWall | UI-复用关键 | xmnote/UIComponents/GalleryJX/XMJXImageWall.swift | docs/component-guides/XMJXImageWall使用说明.md | 新增/重大重构 |
| XMJXThumbnailView | UI-复用关键 | xmnote/UIComponents/GalleryJX/XMJXThumbnailView.swift | docs/component-guides/XMJXThumbnailView使用说明.md | 新增/重大重构 |
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
