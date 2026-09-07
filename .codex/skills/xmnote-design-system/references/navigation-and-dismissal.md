# 导航与退出语义

本参考规定 XMNote 页面如何按真实导航关系和退出结果选择 Back、Cancel、Close、Done/Save 与 Collapse。它覆盖 Tab 根页面、`NavigationStack`、Sheet、full-screen cover、沉浸式内容和可最小化业务层级；不规定业务页面内部布局，也不把某个既有按钮直接升级为通用组件。

新增、修改或审查任何返回、关闭、取消、完成、收起、退出保护或模态内多步流程时读取本文件。涉及具体组件归位时组合读取 [组件与交互](components-and-interaction.md)，涉及符号来源与视觉规格时组合读取 [图标设计与使用](iconography.md)，涉及 Sheet 骨架时组合读取 [业务 Sheet](sheets.md)。

## 先确认关系与退出结果

控件由“当前页面和前一层是什么关系”以及“退出后什么仍然存在”共同决定，不由页面尺寸、物理方向或转场动画决定。实施前至少核对：

1. 当前页面是 Tab 根、导航子页、模态根任务、模态内子步骤，还是持续业务界面的展开态。
2. 点击后是缩短 navigation path、关闭 presentation、放弃草稿、停止任务、提交结果，还是保留状态并最小化。
3. 离场后是否仍有可见紧凑形态，用户能否从该形态直接重新展开。
4. 是否存在未保存内容、进行中的写入或异步任务，退出是否需要阻断或确认。
5. 真实 action、path/presentation owner 与生命周期清理是否和按钮文案一致。

`dismiss()`、`DismissAction` 或 `activeTask = nil` 只证明实现机制，不自动证明用户看到的动作应叫 Close、Cancel 或 Collapse。`fullScreenCover` 只证明内容以全屏模态呈现，也不能决定退出图标。

## 语义决策矩阵

| 页面关系与真实结果 | 用户可见表达 | 实现边界 |
| --- | --- | --- |
| Tab 或一级切换根页面 | 不显示返回 | 通过 Tab、`TopSwitcher` 或对应一级入口切换，不伪造父级 |
| `NavigationStack` 中的子页面，动作只 pop 到父级 | 系统 Back | 优先系统返回按钮与边缘返回手势；只在需要拦截时使用项目返回组件 |
| Sheet/full-screen cover 根任务，退出会放弃草稿、选择或停止该任务 | Cancel／“取消” | 放在语义 cancellation placement；有丢失风险时先确认，有写入时按状态阻断 |
| Sheet/full-screen cover 根页面，无草稿、提交或终止语义 | 标准 Close | 使用系统 Close/xmark；关闭只读内容或临时上下文，不伪装成 Back |
| 用户确认、提交或保存后退出 | Done、Save 或结果明确的业务动词 | 属于完成操作，不是返回；和可放弃任务的 Cancel/Back 路径配对 |
| 持续业务界面的展开态，退出后任务继续、紧凑形态仍可见且可重新展开 | Collapse／向下箭头 | action 必须是 minimize/collapse；任一条件不成立时改用 Close 或 Cancel |

无法从表中得到唯一结论时，先修正或确认页面关系，不以“更像 iOS”“全屏通常向下退出”或相邻页面图标作为决定依据。

## 分层规则

### Back：返回父级

- Back 只表示在同一导航或任务层级中回到上一步，不能关闭整个模态根任务。
- 没有特殊拦截时保留系统 Back 和交互返回手势；不要手写 `Button + chevron.left` 覆盖系统行为。
- 需要在未保存内容、进行中任务或其他业务条件下拦截时，查询 catalog 后使用 `TopBarBackButton` 与 `navigationPopGuard`，并让按钮和手势经过同一个退出判断。
- 模态流程的子步骤使用 Back 返回前一步；不要同时呈现 Back、Cancel、Done 三种竞争路径。

### Cancel：放弃任务

- Cancel 表示离开会放弃尚未提交的草稿、选择或当前任务结果，或停止由该页面生命周期持有的导入、解析等工作。
- 有 Done/Save 的事务型根任务必须保留可放弃路径；退出可能丢失用户生成内容时，按钮和交互式 dismiss 都进入同一确认逻辑。
- 进行中的保存或不可安全中断写入应暂时禁用退出；可安全取消的异步工作在离场时取消，并避免迟到回写。
- Cancel 是结果明确的文字动作，不因页面全屏、左上角空间紧张或希望形式统一而替换成向下箭头。

### Close：关闭模态上下文

- Close 用于只读内容、已经即时生效且没有待提交草稿的工具面板，或其他单纯移除 presentation 的根页面。
- 使用系统 Close/xmark 与明确无障碍标签；不要用返回箭头暗示存在父级，也不要用向下箭头暗示仍有紧凑形态。
- 页面内部释放缓存、取消预取或清理临时资源不一定把用户语义变成 Cancel；判断重点是用户是否放弃了可感知任务或未提交结果。

### Done/Save：完成任务

- Done、Save、确认勾选或业务动词表示接受、提交或完成，不承担返回语义。
- 结果特定、不可逆或会启动新流程的动作使用清楚的业务动词，不为复用 checkmark 抹平成“完成”。
- 多步流程子页面通常以 Back 提供替代路径；根事务任务以 Cancel 提供放弃路径。不要只留下 Done 迫使用户提交后才能退出。

### Collapse：保留并收起

向下箭头只有同时满足以下条件时成立：

1. 离开展开页后，当前会话、播放、计时或同类持续状态继续存在。
2. 原上下文中仍有可见的紧凑承载形态，而不是仅在后台悄然运行。
3. 用户可以从紧凑形态直接重新展开同一状态。

因此，Sheet 支持下拉关闭、full-screen cover 覆盖 Tab Bar、页面转场沿垂直方向退出，都不是使用 `chevron.down` 的证据。若 action 实际执行 dismiss、cancel、stop、clear path 或销毁状态，必须使用 Close 或 Cancel。

当前项目中，阅读计时全屏页的 `.minimize`、持续计时状态和底部附件共同构成有效 Collapse 证据。`TopBarDismissButton` 的真实 owner 与可访问性文案仍是阅读计时专用，在出现第二个独立且同语义的生产场景前不能泛化。

`MainTabView` 私有的 `AppTaskRootDismissControlStyle.collapse` 以及内容查看、阅读日历的现存调用只属于待审查实现，不具备“持续状态 + 可见紧凑形态 + 可重新展开”的完整证据，不能作为后续页面使用向下箭头的范例。

## 呈现方式不决定退出表达

- `NavigationStack` 描述层级导航；子页面默认 Back，根页面没有可 pop 父级时不得伪造 Back。
- Sheet 与 full-screen cover 都可以承载模态任务；根页面仍按实际结果选择 Cancel 或 Close，子步骤按 path 选择 Back。
- full-screen cover 覆盖底层 Tab Bar 是呈现层级的结果，不代表内容从底部“展开”，也不代表应显示向下箭头。
- 系统下拉手势是 dismiss 的一种输入方式，不等于工具栏需要绘制同方向 glyph。手势与按钮必须触发一致的退出保护和业务结果。
- 仅用于切换范围或保留多个已激活页面状态的 `TopSwitcher`、`XMScopeSelector`、`KeepAliveSwitcherHost` 不建立返回层级；真正导航也不得伪装成切换器。

## 组件、位置与可访问性

- 普通 push 子页优先系统 Back；特殊拦截查询 `TopBarBackButton` 和 `navigationPopGuard`。
- 普通业务 Sheet 使用 `XMSheetScaffold` 持有 cancellation/confirmation placement，不在页面内重建标题栏或关闭壳层。
- Back/Close/Collapse 使用 SF Symbols 或系统组件。Cancel、Save、开始、解析、加入等结果明确的动作保留文字；图标不能成为未知结果的唯一说明。
- 使用 `.navigation`、`.cancellationAction`、`.confirmationAction` 等语义 placement，不用物理左右位置反推角色。依赖系统处理 RTL，定制方向性图标时仍需单独验证。
- 返回、关闭和收起保持系统色或中性色，不因可点击使用品牌填充；系统栏已有外观时不再套自定义 glass/material。
- 独立图标按钮达到 `InteractionMetrics.minimumTouchTarget`，VoiceOver label 描述动作结果，例如“返回”“关闭内容查看”“收起阅读计时”，不得朗读“左箭头”“叉号”或“向下箭头”。

## 验证清单

每次新增或修改退出入口至少验证：

1. Tab 根、push 子页、模态根、模态子步骤或持续展开态分类唯一。
2. 按钮 action、系统手势、程序化退出和异步清理产生相同业务结果。
3. Back 只 pop 一层；Cancel 放弃/停止的内容与文案一致；Close 不暗示提交；Done/Save 只在成功后退出。
4. Collapse 离场后仍能看到紧凑形态，持续状态未被销毁，并可重新展开同一实例。
5. 未保存、写入中、失败恢复和交互式 dismiss 均经过同一保护 owner。
6. 默认字号、辅助功能字号、最长本地化、RTL、VoiceOver 顺序和 44pt 点击区成立。

## Apple 平台证据

- [Toolbars HIG](https://developer.apple.com/design/human-interface-guidelines/toolbars)：标准 Back 用于回溯信息层级，标准 Close 用于关闭模态界面。
- [Modality HIG](https://developer.apple.com/design/human-interface-guidelines/modality)：模态任务需要明确退出路径；关闭可能丢失内容时提供保护。
- [Sheets HIG](https://developer.apple.com/design/human-interface-guidelines/sheets)：Cancel/Close、Done 与 Back 分别承担放弃、完成和返回前一步，避免同时展示三者。
- [Gestures HIG](https://developer.apple.com/design/human-interface-guidelines/gestures)：快捷手势补充而不替代标准导航入口。
- SwiftUI [`cancellationAction`](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/cancellationaction)、[`navigation`](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/navigation)、[`DismissAction`](https://developer.apple.com/documentation/swiftui/dismissaction) 与 [`fullScreenCover`](<https://developer.apple.com/documentation/swiftui/view/fullscreencover(item:ondismiss:content:)>) 用于核对 placement、dismiss 机制和呈现关系；API 名称不替代上述用户语义判断。
- [Apple Music Classical 播放器](https://support.apple.com/en-ca/guide/apple-music-classical/dev418ee3f2d/web) 与 [Shazam 正在播放](https://support.apple.com/guide/shazam/dev3e403546e/web) 只支持“持续状态在展开态与紧凑态之间收起”的证据，不支持把向下箭头泛化为 modal close。
- [iPhone 照片编辑](https://support.apple.com/guide/iphone/iphb08064d57/ios) 支持事务型编辑以 Cancel/Done 区分放弃和完成。

Apple 系统应用实例用于校验语义，不覆盖 XMNote 当前真实 owner、状态生命周期和组件准入。平台 API 或 HIG 更新时按仓库要求重新通过 `apple-doc-mcp` 查证。
