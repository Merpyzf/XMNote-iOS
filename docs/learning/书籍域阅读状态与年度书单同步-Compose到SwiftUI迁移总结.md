# 书籍域阅读状态与年度书单同步：Compose 到 SwiftUI 迁移总结

更新日期：2026-06-06

## 核心结论

Android -> iOS 迁移时，阅读状态不是一个简单字段。它同时影响状态历史、`book` 当前快照、读完进度、评分和年度书单关系。SwiftUI 页面层不应直接复制 Android ViewModel 的写库片段，而应把这些副作用收敛到 Repository 内部 helper，让新增、编辑和批量入口共享同一条 GRDB 事务语义。

## 从 Compose 迁移到 SwiftUI 的差异

| Android/Compose 常见形态 | iOS/SwiftUI 落地方式 | 迁移要点 |
| --- | --- | --- |
| ViewModel 调 `BookRepository.updateBookReadStatus` 后 Toast 提示。 | ViewModel 调 Repository，页面展示 `BookshelfActionFeedback`。 | Toast 是业务反馈意图，不是 iOS 视觉形态；iOS 用上下文内状态、忙态禁用和错误保留。 |
| Repository 直接在 Room transaction 中串联 DAO。 | Repository 的 GRDB write 闭包中调用内部 helper。 | helper 只接收 `Database`，避免跨事务和跨 Repository 复制 SQL。 |
| 新增书在 `addBook` 事务内设置 order、插状态历史、同步年度书单。 | `BookEditorRepository.saveBook` 在同一 GRDB 写事务里完成 order、状态历史和年度同步。 | 不要把“新增书”和“编辑状态”混成同一个强制读完进度逻辑。 |
| Compose 网格按排序条件临时拼字段展示。 | Domain 模型提供 `sortAuxiliaryText(for:)`，网格组件只负责渲染。 | 排序上下文文案应该统一来源，默认书架和二级列表共享。 |

## 数据写入模式

Android 的核心业务意图：

```kotlin
noteDb.runInTransaction {
    val newest = readStatusRecordDao.queryNewestReadStatusFromBook(bookId, 0)
    if (newest?.readStatusId == statusId) {
        readStatusRecordDao.updateLatestBookReadStatus(bookId, statusId, changedDate)
    } else {
        readStatusRecordDao.insert(record)
    }
    bookDao.updateReadStatus(userId, bookId, statusId, changedDate)
    if (statusId == READ_DONE) {
        markBookAsFinished(book)
    }
    syncAnnualCollectionAfterReadHistoryChanged(bookId)
}
```

iOS 对应模式：

```swift
try dbPool.write { db in
    try BookReadStatusMutation.updateBookReadStatus(
        db,
        bookID: bookID,
        statusID: statusID,
        changedAt: changedAt,
        updatedAt: now,
        finishedRatingScore: ratingScore
    )
}
```

关键不是逐行翻译，而是确保同一个事务里发生相同副作用，并让编辑页和批量入口共享同一 helper。

## 年度书单同步经验

- 年度归属要从有效读完历史计算，不能只看 `book.read_status_id` 当前快照。
- 但旧数据可能只有当前快照，因此需要把 `book.read_status_changed_date` 作为兜底年份来源。
- 失效年度关系只软删关系表，不随手补额外 `updated_date`，否则会制造和 Android 不一致的同步语义。
- 年度 collection 缺失时按 Android 字段语义创建，避免 iOS 单端产生特殊集合。

## 交互经验

- Android Toast 对应的是“用户需要知道写操作是否完成”，不是“iOS 也要弹一条 Toast”。
- iOS 写操作应该立即进入可感知状态，并禁用重复触发；短成功、长错误，是比瞬时 Toast 更符合 HIG 的反馈。
- 未完成模块入口宁可隐藏，也不要让用户点进只会提示“迁移后开放”的菜单项。
- 网格辅助文案应是一行稳定信息，不能因为排序切换造成封面、标题和选择态跳动。

## 给 Android Compose 开发者的检查清单

- 先找 Android 真实 owner：Fragment/ViewModel 只是触发点，事务语义通常在 Repository/DAO。
- 再找 iOS 真实写入点：ViewModel 只调 Repository，GRDB SQL 必须在 Data 层。
- 区分字段更新和业务副作用：阅读状态会影响历史、进度、评分和年度书单。
- 交互只对齐意图：Toast、Activity、BottomSheet 不能机械迁移，应该换成 iOS 用户熟悉的反馈与导航。
