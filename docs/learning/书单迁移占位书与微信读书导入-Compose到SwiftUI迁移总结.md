# 书单迁移占位书与微信读书导入：Compose 到 SwiftUI 迁移总结

更新日期：2026-06-27

## 核心结论

Android 书单模块的关键不是“列表里放一组书”，而是 `collection`、`collection_book` 和 `book.is_deleted` 共同表达的关系语义。在线搜索、手动创建和微信读书导入得到的书，可能还没有进入书架，但已经属于某个书单；因此 iOS 必须保留占位书能力，而不是把远端书强行落成有效书架书籍。

SwiftUI 迁移时，页面层负责清楚表达“书单中的书”和“书架中的书”的差异，Repository 负责让占位书、relation、年度同步和导入事务保持 Android 数据语义。

## 从 Compose 迁移到 SwiftUI 的差异

| Android/Compose 常见形态 | iOS/SwiftUI 落地方式 | 迁移要点 |
| --- | --- | --- |
| `Activity`/`Fragment` 通过事件总线接收选书、编辑和分享结果。 | SwiftUI 通过 Sheet 闭包、Observable ViewModel 和路由回调传递结果。 | 不要把事件总线机械搬到 iOS；保持单页状态 owner 清晰。 |
| 在线书、手动创建书以 `book.isDeleted = 1` 保存到书单。 | `BookCollectionPlaceholderBookDraft` 先成为占位书，再写入 relation。 | 占位书不是坏数据，是 Android 书单收集未入库书籍的业务能力。 |
| 微信读书系统分享直接解析并保存。 | 应用内导入先预览，系统分享可直接保存但复用同一 Repository。 | iOS 可在不破坏对齐的情况下增加预览确认，降低网页结构变化风险。 |
| 年度书单编辑页禁用标题但允许改简介。 | iOS 明确拆分年度说明、年度点评和自动同步成员。 | UI 文案要比 Android 更清楚，底层字段保持一致。 |
| Toast 表示保存、删除、导入成功或失败。 | `BookshelfActionFeedback` 和系统分享面板表达结果。 | 对齐反馈意图，不对齐 Toast 外观。 |

## 占位书迁移模式

Android 的业务事实：

```kotlin
if (book.id == 0L) {
    bookDao.insertSync(BookModelMapper().transform(book.apply {
        this.isDeleted = 1
    }))
}
collectionBookDao.insert(...)
```

iOS 对应模式：

```swift
let bookID = try insertCollectionPlaceholderBook(db, draft: draft)
try insertCollectionBookRelationIfNeeded(
    db,
    bookID: bookID,
    collectionID: collectionID,
    recommend: draft.recommend
)
```

要点：

- 占位书必须保留封面、标题、作者、简介和 relation 文本。
- 手动书单读取占位书，年度书单不读取占位书。
- 恢复占位书时只改变书架有效性和阅读状态，不重建 relation。
- 去重口径按 Android 的书名+作者判断，避免远端结果和本地书重复插入同一书单。

## 微信读书导入经验

Android 系统分享是直接保存，速度快，但失败时容易把半成品写进数据库。iOS 可以采用更安全的分层：

1. `WereadCollectionLinkExtractor` 只负责从 URL 或分享文本里提取微信读书链接。
2. `BookCollectionImportRouter` 把深链或 Share Extension handoff 转成书单页请求。
3. Repository 抓取 HTML 并解析为 `BookCollectionImportPreview`。
4. 用户确认后保存书单、占位书和 `collection_book.recommend`。

这个模式对 Compose 开发者的启发是：分享入口不要直接绑定写库逻辑，先抽一个“可预览的领域对象”，再由用户确认进入事务。

## 年度书单经验

年度书单有三层语义：

- 标题和成员来自系统同步，不允许用户直接改。
- 年度说明属于整个年度书单，写 `collection.desc`。
- 年度点评属于某一本书在年度书单中的 relation，写 `collection_book.recommend`。

Compose 里如果一个页面既能编辑书单又能编辑 relation，很容易用一个 `isEditable` 控制全部能力。SwiftUI 迁移时要拆分结构编辑权限和 relation 文本编辑权限，避免年度书单变成完全只读。

## 给 Android Compose 开发者的检查清单

- 先找到真实写库点，不要只看 Fragment/Activity 的点击事件。
- 看到 `is_deleted = 1` 不要默认当作删除垃圾数据，先确认它是否承载占位业务。
- 导入类功能优先设计“预览对象”，再进入 Repository 事务。
- 同一数据库字段可以有不同 UI 文案，但底层命名不要为了文案而分叉。
- Android Toast、Dialog、Activity 只说明用户需要感知和跳转，不决定 iOS 的视觉形态。
- 对齐文档必须把缺口写出来；未实现的 Android 能力不能用“平台差异”掩盖。
