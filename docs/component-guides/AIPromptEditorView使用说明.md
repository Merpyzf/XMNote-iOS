# AIPromptEditorView 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Personal/AIPromptEditorView.swift`。
- 角色：“我的 > AI 配置”内三类任务的独立提示词编辑页。
- 边界：页面持有导航、焦点、选区和 Sheet 等 UI 瞬态；`AIPromptEditorViewModel` 持有草稿与异步状态；`AIRepositoryProtocol` 负责读取、校验、原子保存和请求能力；`NoteRepositoryProtocol` 只为试运行书摘选择提供分页数据。
- 归属：UI 核心页面，不是跨功能复用组件；变量编辑器和次级 Sheet 继续保持 Personal feature-private。

## 快速接入

页面通过 `PersonalRoute.aiPromptEditor` 进入，并从环境读取 `RepositoryContainer`：

```swift
NavigationLink(value: AppRoute.personal(.aiPromptEditor(.noteExplanation))) {
    Text("书摘解读")
}
```

路由目的地：

```swift
case .aiPromptEditor(let kind):
    AIPromptEditorView(kind: kind)
```

不要在调用点另建 ViewModel 或直接注入 `AIConfigurationStore`，页面壳层会从 Repository 环境构造状态 owner。

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `kind` | `AIPromptKind`，决定默认 Prompt、允许变量、校验契约、样例上下文和正式输出协议。 |

环境依赖：

| 环境值 | 说明 |
| --- | --- |
| `RepositoryContainer` | 提供 `aiRepository` 与 `noteRepository`，View/ViewModel 不直接访问 UserDefaults、数据库或网络客户端。 |

## 示例

```swift
struct PromptEntryExample: View {
    var body: some View {
        NavigationStack {
            AIPromptEditorView(kind: .autoTag)
        }
        .environment(
            RepositoryContainer(
                databaseManager: DatabaseManager(database: try! .empty())
            )
        )
    }
}
```

生产代码应优先使用类型安全路由；直接构造主要用于 Preview 或隔离验证宿主。

## 行为合同

- 用户提示词和系统提示词组成一个任务模板，保存时作为同一快照处理。
- 变量只在用户提示词中自动替换；系统提示词出现 `${...}` 时按普通文本保留并提示。
- 阻断问题存在时不能保存、预览或试运行；推荐变量缺失只提示风险。
- 恢复默认只修改草稿；用户仍需显式保存。
- 有未保存内容时，顶部返回和系统交互式返回共用保存/放弃/继续编辑确认。
- 试运行和优化只由用户显式触发；关闭 Sheet 或输入快照变化后，旧响应不能回写。
- 试运行默认使用《百年孤独》固定书摘；正文可直接编辑，也可从本地书摘搜索选择，选择后保留书名、作者、章节、想法与标签元数据。
- AI 查词必须在原生正文编辑器中选中单段非空文字；插入点、空白和多重选区不能开始测试。
- “与应用原始提示词对比”始终复用同一书摘、凭据、模型和生成参数，只替换模板；两个流独立完成或失败，并通过选择器和水平滑动查看。
- AI 结果统一使用 `AIMarkdownResultView` 渲染累计 Markdown，不展示请求或调用次数。

## 常见问题

### 为什么这是 push 页面而不是 Sheet？

主任务包含长文本、键盘、变量命令栏、双字段切换与多个按需次级任务，需要稳定的导航和编辑现场。次级预览、试运行和优化才使用 item-driven Sheet。

### 为什么不能直接保存整份 AI 配置？

编辑页只拥有当前任务 Prompt。Repository 会让 Actor Store 读取最新配置、替换当前任务并一次写回，避免覆盖设置页或其他任务的较新修改。

### “与应用原始提示词对比”具体比较什么？

它比较当前编辑中的模板与 `AIPromptConfiguration.androidAlignedDefault`。两边使用完全相同的书摘、凭据、模型和生成参数，页面只呈现两份原始结果，不再额外生成总结或评分。当前模板与应用原始模板一致时，对比入口会禁用。

### 为什么变量视觉不能直接写入配置？

变量的跨层合同是 `${变量名}` 纯文本。TextKit 的颜色、令牌附件与投影范围只属于编辑体验，不能进入配置快照或请求模型。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
