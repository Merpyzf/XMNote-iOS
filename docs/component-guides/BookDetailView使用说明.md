# BookDetailView 使用说明

## 组件定位

- 源码入口：`xmnote/Views/Book/BookDetailView.swift`。
- 原生列表桥接：`xmnote/Views/Book/Components/BookWorkspaceCollectionView.swift`。
- 展示派生层：`xmnote/ViewModels/Book/BookWorkspacePresentationStore.swift`。
- 角色：单本书的四域工作台，常驻目录、书摘、相关和书评四个 `UICollectionView`，保留各域滚动现场。
- 边界：页面从环境读取 Repository，但导航栈由外层回调持有；筛选是页面局部状态，排序统一写入 `BookContentSortRule`。

## 快速接入

页面必须位于已注入 `RepositoryContainer` 与 `AppNavigationCoordinator` 的书籍导航栈内：

```swift
BookDetailView(
    bookId: book.id,
    onStartReading: startReading,
    onSupplementReading: supplementReading,
    onOpenReadingDetail: openReadingDetail,
    onOpenChapterNotes: openChapterNotes,
    onOpenBook: openBook,
    onOpenBookRoute: openBookRoute
)
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `bookId` | 当前书籍数据库 ID；变化时页面会重建唯一状态源。 |
| `onStartReading` | 开始阅读计时，由根导航 owner 处理全屏任务。 |
| `onSupplementReading` | 补记阅读记录入口。 |
| `onOpenReadingDetail` | 打开阅读详情。 |
| `onOpenChapterNotes` | 打开指定章节的书摘集合。 |
| `onOpenBook` | 从相关书籍进入另一单书工作台。 |
| `readingTimerZoomConfiguration` | 阅读计时器缩放转场源；无匹配场景可传 `nil`。 |
| `onOpenBookRoute` | 打开章节管理、书籍编辑等当前 Tab 内路由。 |

## 示例

### 从书籍路由进入

```swift
case .detail(let bookID):
    BookDetailView(
        bookId: bookID,
        onOpenBookRoute: { route in
            navigationCoordinator.pushBook(route)
        }
    )
```

### 打开章节管理

工作台只发送路由意图，不直接维护 `NavigationPath`：

```swift
onOpenBookRoute(.chapterManager(bookID: bookID, focusChapterID: nil))
```

## 状态与性能约束

- `BookDetailViewModel` 是数据库观察和业务写入 owner；页面不直接访问 `AppDatabase`。
- `BookWorkspacePresentationStore` 在后台生成可取消快照，并用 revision 丢弃过期结果。
- `BookWorkspaceCollectionView` 只应用最新 diffable snapshot；四域列表常驻但仅显示当前域。
- 展开态按内容 ID 保存在展示 Store，列表复用不能把上一行展开状态带给下一行。
- 删除继续使用 Android v45 的 `is_deleted` 软删除语义，禁止在页面层改成物理删除。

## 常见问题

### 为什么不恢复 SwiftUI 版 BookContentWorkspaceView？

最终展示壳已经统一为原生 Collection 工作台。保留第二套页面会产生两套滚动、快照和排序语义，后续功能容易再次分叉。

### 为什么切换四域时不重新创建列表？

常驻列表能保存各域滚动位置和展开状态，连续退出重进时再由持久化排序与最新数据库快照恢复内容。

### 目录筛选会写入持久化设置吗？

不会。目录展开与筛选是本次页面会话的局部状态；跨会话排序只使用 `BookContentSortRule`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
