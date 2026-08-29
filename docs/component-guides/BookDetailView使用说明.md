# BookDetailView（书籍工作台）使用说明

## 组件定位

- 统一页面名称：书籍工作台（Book Workspace）。
- 源码路径：`xmnote/Views/Book/BookDetailView.swift`。
- 代码入口：`BookDetailView`。该类型名为兼容现有路由保留，不代表产品页面仍称“书籍详情页”。
- 角色：单书核心页面壳层，聚合共享书籍信息头部、目录、书摘、相关、书评、搜索与单书操作。
- Android 对应：`NoteManagerActivity`，对齐业务职责和信息项，不要求视图实现同构。

## 快速接入

最小接入只需要稳定的书籍 ID：

~~~swift
BookDetailView(bookId: bookId)
~~~

生产路由通常同时注入阅读、章节和关联书籍跳转：

~~~swift
BookDetailView(
    bookId: bookID,
    onStartReading: { bookID in
        coordinator.present(.readingTimer(bookId: bookID))
    },
    onSupplementReading: { bookID in
        coordinator.present(.readingRecord(bookId: bookID))
    },
    onOpenReadingDetail: { bookID in
        path.append(BookRoute.readingDetail(bookId: bookID))
    },
    onOpenChapterNotes: { bookID, chapterID, title in
        path.append(
            BookRoute.chapterNotes(
                bookId: bookID,
                chapterId: chapterID,
                title: title
            )
        )
    },
    onOpenBook: { linkedBookID in
        path.append(BookRoute.workspace(bookId: linkedBookID))
    }
)
~~~

示例中的 route 名称用于说明职责，实际接入以调用方已有 route enum 为准。

## 参数说明

| 参数 | 类型 | 必填 | 职责 |
| --- | --- | --- | --- |
| `bookId` | `Int64` | 是 | 目标书籍的稳定主键，也是 Repository observation 的查询条件 |
| `onStartReading` | `(Int64) -> Void` | 否 | 打开阅读计时；默认无操作 |
| `onSupplementReading` | `(Int64) -> Void` | 否 | 打开补录阅读；默认无操作 |
| `onOpenReadingDetail` | `(Int64) -> Void` | 否 | 打开阅读详情；封面和阅读时长复用该入口 |
| `onOpenChapterNotes` | `(Int64, Int64, String) -> Void` | 否 | 打开指定章节的书摘列表 |
| `onOpenBook` | `(Int64) -> Void` | 否 | 从相关内容进入另一本文书的书籍工作台 |
| `readingTimerZoomConfiguration` | `ReadingTimerZoomSourceConfiguration?` | 否 | 阅读计时转场源配置；没有匹配转场时传 `nil` |
| `onOpenBookRoute` | `(BookRoute) -> Void` | 否 | 打开章节管理、书籍编辑等当前 Tab 内路由；默认无操作 |

## 环境依赖

页面需要上层环境提供：

- `RepositoryContainer`：构造 `BookDetailViewModel` 所需的书籍 Repository 和封面取色 Repository。
- `AppNavigationCoordinator`：展示内容查看器、书摘编辑器和控制外层 Tab Chrome。
- 当前 `NavigationStack`：承接返回和调用方注入的深层路由。

环境缺失不是页面内部可恢复状态，生产接入应复用 App 根部已有注入链路。

## 结构与状态边界

### 页面层

- `BookDetailView` 只创建宿主并转交路由能力。
- `BookWorkspaceContentView` 持有当前域、搜索词、筛选/排序、目录展开和加载门闩。
- `BookDetailViewModel` 观察书籍、书摘、相关和书评；页面消失时停止 observation。
- 编辑、排序与删除统一由 ViewModel 经 Repository 执行；删除遵循项目已批准的物理清理语义。

### 展示派生层

- `BookWorkspacePresentationStore` 将四域输入转换为不可变 Collection 快照。
- 只重建真实变化的内容域；搜索使用 150ms 去抖。
- 每个域通过独立 revision 拒绝过期异步结果。

### 原生列表层

- `BookWorkspaceCollectionView` 是 SwiftUI 到 UIKit 的页面私有桥接。
- `BookWorkspaceCollectionHostView` 常驻四个 `UICollectionView`，统一管理共享 Header、Scope Bar、分页、吸顶和滚动位置。
- 高频连续几何不写回 SwiftUI；业务选中态只在分页落定后提交。

### 四域状态与视口定位

- 目录、书摘、相关和书评均由 Collection 快照显式表达加载、空数据、搜索无结果和读取失败，状态正文统一复用 `XMCompactStateView`；加载反馈复用 `LoadingStateView`。
- 普通空态只陈述事实，例如“暂无目录”；当前域存在搜索词时使用 `.noResults`，例如“没有匹配的目录”。两者不能混用。
- 状态属于 Tab 内局部内容，不升级为页面级大状态，也不在状态内部重复顶部或工具栏已有动作。
- 状态行高度由宿主使用当前可见高度、`adjustedContentInset`、书籍 Header 和 Scope Bar 的真实测量值计算，并以页面私有的 280pt 为下限。状态正文因此几何居中在 Scope Bar 下方与底部系统栏上方，不使用固定偏移。
- 空状态 section 只保留水平页面边距，不增加额外纵向 inset，也不制造虚假滚动范围；书籍 Header 保持展开且继续保留系统回弹。
- 安全区、动态字体、底部栏或共享 Chrome 几何变化时，宿主只重配状态 Cell，并沿用现有视口锚点无动画恢复，避免四个 Tab 切换时跳位。

## 书籍头部规则

- 书名、作者、出版社、出版日期、封面和阅读状态组成身份区。
- 出版日期为空或为 `1970-01-01` 时隐藏。
- 阅读状态文案支持“2 刷”“2 刷中”，颜色由阅读状态 ID 决定。
- 阅读时长和评分只在大于 0 时显示。
- 书签、阅读进度独立显示且可同时出现。
- 所有指标均无有效值时，不保留指标空行。
- 书摘数量在头部指标与 Tab 同步展示，点按头部指标切换到书摘域。
- 当前 Header 只展示作者；“作者 / 译者”组合仍是独立待实施事项。

## Tab 与动画边界

- Scope Bar 和书籍 Header 各只有一个视觉实例。
- 主题取色只动画背景颜色，不能对整个 Tab 容器使用交叉溶解。
- 指示线初始隐藏，标题几何有效后无动画落位。
- 用户点击或横向拖动时，Pager 连续位置直接驱动指示线。
- 首次布局、外部选中态同步、动态字体和旋转不得启动指示线独立位移动画。
- Reduce Motion 下程序化分页和 Tab 可见区域调整立即完成。

## 示例

### 示例 1：从书架进入书籍工作台

由书架 route 保存 `bookId`，在当前书籍 Tab 的 `NavigationStack` 中 push `BookDetailView`。返回后继续保留书架现场。

### 示例 2：从相关内容打开另一本文书

将 `onOpenBook` 交给外层 route owner。页面内部只上报目标书籍 ID，不直接创建新的 `NavigationStack`。

### 示例 3：只读预览或 SwiftUI Preview

可以只传 `bookId`，但必须同时提供 Preview Repository 环境；默认空闭包只代表关闭动作入口，不会替代数据依赖。

## 常见问题

### 1. 为什么产品名称是“书籍工作台”，代码仍叫 `BookDetailView`？

`BookDetailView` 已是现有路由和白名单中的稳定类型。当前先统一产品与文档口径，避免为了命名引入与功能无关的跨模块重命名。新增页面私有类型统一采用 `BookWorkspace*`。

### 2. 为什么不使用全局 `XMScopeSelector`？

本页 Tab 需要与原生 Pager 的连续位置、共享 Chrome 和四个 Collection 的滚动生命周期直接协作，属于页面私有实现，不满足跨模块复用条件。

### 3. 为什么四个内容域都常驻？

常驻可以稳定保留各域滚动位置和列表状态。非活动页会关闭交互、辅助技术访问和预取，降低无效资源消耗。

### 4. 为什么指示线不能自己做 spring 动画？

指示线是 Pager 位置的几何投影。再启动独立动画会产生两个时间轴，用户快速拖动或主题变化时容易落后、回跳或产生残影。

### 5. 这个组件是否可抽到 `UIComponents`？

不建议。它绑定单书业务模型、四域快照、路由和滚动策略，是核心页面壳层；共享能力应先在多个独立页面证明相同根因与修复模式后再抽象。

### 6. 是否允许子视图直接访问 Repository？

不允许。数据读取经 `BookDetailRepositoryProtocol`，由 `BookDetailViewModel` 编排；Header、Scope Bar 和列表 Item 只消费展示模型与回调。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
