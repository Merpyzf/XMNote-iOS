# ChapterManagerView 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Book/ChapterManagerView.swift`。
- 角色：单本书五层目录的新增、编辑、星标、移动、排序、批量导入与删除入口。
- 边界：页面通过 `ChapterManagerViewModel` 使用 `ChapterManagementRepositoryProtocol`，不直连数据库。

## 快速接入

```swift
ChapterManagerView(bookID: bookID)
```

定位到指定章节：

```swift
ChapterManagerView(bookID: bookID, focusChapterID: chapterID)
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `bookID` | 目录所属书籍 ID。 |
| `focusChapterID` | 可选目标章节；用于从单书工作台定位，缺省时从顶部开始。 |

## 示例

```swift
case .chapterManager(let bookID, let focusChapterID):
    ChapterManagerView(bookID: bookID, focusChapterID: focusChapterID)
```

读取状态使用延迟显示的 `LoadingGate`；所有结构写入即时显示门闩，移动操作失败时保留解释，成功后可在限定时间撤销。

## 常见问题

### 排序能跨父章节拖动吗？

同级排序与跨父级移动是两种操作。排序只提交同级 ID 顺序；跨层级必须走移动 Sheet 并由 Repository 校验层级和环路。

### 删除章节会物理删除书摘吗？

不会。章节关系和书摘删除遵循 Android v45 数据语义，页面不擅自替换为硬删除。

### OCR 与远端同步在页面里直接访问网络吗？

不访问。页面创建对应 ViewModel，实际数据能力继续通过 Repository 注入。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
