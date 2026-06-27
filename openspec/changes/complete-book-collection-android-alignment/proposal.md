## Why

iOS 书单模块已经完成列表、详情、排序、收藏理由、年度点评和导出占位入口等核心体验，但与 Android 端仍存在多条完整业务链路差异：添加来源不完整、占位书不可恢复、微信读书书单不能导入、当前书单不能真实导出、书单分享长图缺失、年度书单本体说明语义缺失、书单分组选择不能记忆。现在需要一次性制定完整对齐计划，确保 iOS 可以保留自身 UI/UX 创新，同时不遗漏 Android 已有书单能力。

## What Changes

- 补齐手动书单的完整添加书籍链路：本地书、多选、在线搜索结果、手动创建结果均可进入书单；继续保留底部 Liquid Glass `添加书籍` 作为高频入口。
- 支持书单内占位书展示与恢复：对 Android `is_deleted = 1` 语义进行 iOS 化表达，用户可将仅存在于书单关系中的书加入书架或开始阅读。
- 增加微信读书书单链接导入能力：识别书单链接、解析标题/简介/书籍/推荐语，先展示导入预览，再保存为 iOS 书单。
- 将当前 `导出此书单` 占位入口升级为真实当前书单批量导出能力，默认范围必须锁定当前书单，避免退化为全书架导出。
- 补齐书单分享长图能力：从详情页生成适合分享的书单视觉卡片或长图，包含书单信息、书籍信息与 relation 文本。
- 为年度书单增加本体级 `年度寄语` 或 `年度说明`，与单本书 `年度点评` 区分；年度成员仍由读完记录自动同步。
- 记住书单首页最近选择的分组：`我的书单` / `年度书单` 在下次进入时保持用户上次选择，并在空年度书单场景保留合理回退。
- 保持上一轮已落地的语义边界：普通书单 relation 文本继续称为 `收藏理由`，年度单本书 relation 文本继续称为 `年度点评`；底部 Liquid Glass 只承载真实高频操作。

## Capabilities

### New Capabilities
- `book-collection-complete-add-flow`: 手动书单支持本地、在线、手动创建、多选等完整添加来源，并保持 iOS 现有底部添加入口体验。
- `book-collection-placeholder-books`: 书单内支持 Android 对齐的占位书关系展示、打开与恢复到书架/阅读的能力。
- `book-collection-weread-import`: 支持从微信读书书单链接导入书单，包含预览确认、占位书保存与 relation 推荐语保留。
- `book-collection-current-export`: 当前书单批量导出从占位入口升级为真实导出，导出范围固定为当前书单。
- `book-collection-share-image`: 书单详情支持生成并分享视觉化书单长图或卡片。
- `annual-book-collection-overview-note`: 年度书单支持本体级年度寄语/说明，与单本书年度点评区分。
- `book-collection-kind-preference`: 书单首页记住用户最近选择的书单分组，并在空数据场景做合理回退。

### Modified Capabilities
无。当前主 `openspec/specs` 尚无已归档书单规格；上一轮 `align-book-collection-export-annual-notes` 的导出入口与年度点评作为已完成 change 事实，在本变更的设计与任务中按前置现状承接，不在本变更中声明为主规格修改。

## Impact

- Android -> iOS 对齐影响：补齐 Android 已有的书单添加、占位书、微信读书导入、分享长图、当前书单导出、年度简介编辑、分组选项记忆等业务语义；iOS 可以改进文案、确认流程与视觉呈现，但不得少于 Android 能力。
- 数据影响：预计需要读取与写入 Android 对齐的 `book.is_deleted`、`collection_book.recommend`、`collection.desc` 等字段；若新增本地偏好字段，只能用于 iOS UI 状态，不得改变数据库 schema。任何数据库读写、软删除语义、事务边界、冲突策略都必须先核对 Android 端事实。
- Repository 影响：新增或扩展书单 Repository 能力，ViewModel 不直接访问数据库、网络或 WebDAV；微信读书导入与在线书籍创建必须通过 Repository 或既有搜索/编辑服务链路。
- UI/导航影响：书单详情更多菜单、底部 Liquid Glass 添加入口、书籍 Item 占位状态、导入预览、导出流程、分享预览、年度说明编辑 Sheet、书单首页分段选择会受影响。内容层不得新增装饰性 Liquid Glass。
- 依赖影响：分享长图与导出涉及 SwiftUI 渲染、文件生成、系统分享或文件导出 API；实现前必须查 Apple 官方文档或项目内 iOS 26/Liquid Glass 学习文档。
- 风险边界：微信读书网页结构可能变更；占位书恢复会影响书架排序和阅读状态；当前书单导出是否包含 relation 文本需要在设计中明确，避免重复 Android 的范围和字段歧义。
