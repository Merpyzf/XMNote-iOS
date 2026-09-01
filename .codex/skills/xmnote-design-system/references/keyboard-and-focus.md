# 软键盘与输入焦点

本参考是 XMNote 所有文本输入场景的键盘、焦点、滚动收起与布局避让规范。它同时覆盖普通页面、业务 Sheet、搜索、表单、多行编辑、富文本、SwiftUI/UIKit 桥接、集合列表和固定底部操作，不只约束 Sheet。

本文件只定义交互与实现决策，不提供新的公共 modifier、组件或全局状态。涉及输入控件外观、字段文案、尺寸和错误样式时继续读取 [组件与交互](components-and-interaction.md)；涉及 Sheet 骨架、Detent 和退出关系时同时读取 [业务 Sheet](sheets.md)。

## 事实来源与优先级

1. 用户当次明确要求与仓库 `AGENTS.md`。
2. 当前 SDK 的 Apple 文档、HIG 与 WWDC 平台说明。
3. XMNote 当前真实 owner、运行证据和多个独立生产场景。
4. 社区维护者的一手资料，只用于识别常见失效模式和兼容风险。

社区文章、代码片段或第三方库不能覆盖 Apple 平台语义，也不能单独证明 XMNote 应新增公共抽象。Apple 没有规定所有页面使用同一种收起模式；必须按用户任务、滚动 owner 和手势关系选择。

## 当前 App 事实快照

以下数据来自 2026-09-01 当前 worktree，只用于说明既有模式和迁移起点，不是永久统计。修改相关页面前必须重新搜索真实代码，不能引用本节数字代替现场审计。

- 46 个生产 Swift 文件直接使用 `TextField`、`SecureField`、`TextEditor` 或 `.searchable`。
- 11 个场景显式使用 SwiftUI `.scrollDismissesKeyboard(.interactively)`；`GlobalSearchRootView` 有一个 `.never` 的连续搜索例外。
- 3 个 UIKit 文本编辑器使用 `keyboardDismissMode = .interactive`，包括富文本、提示词 Token 编辑和优化要求编辑。
- 5 个 UIKit 集合列表使用 `.onDrag`，用于搜索或浏览时首拖快速释放内容空间。
- 13 个文件使用 `@FocusState`；`XMInlineSearchField` 是纯 SwiftUI 焦点范例，`XMSystemSearchBar` 是受控 UIKit first responder 桥接。
- `BookshelfCollectionKeyboardAvoidanceCoordinator` 与 `NoteEditorView` 监听键盘 frame。前者处理集合 inset，后者还承担编辑器展开/收束时序；两者都不是普通页面模板。
- `BookContainerView`、`BookSearchView`、`BookshelfBookListView` 和 `AIPromptEditorView` 仍存在全局 `UIApplication.sendAction` 遗留调用。新代码不得复制，后续按真实焦点 owner 逐步迁移。

代表性现状可归纳为：

| 类型 | 当前代表 owner | 结论 |
| --- | --- | --- |
| SwiftUI 滚动编辑 | `AIConfigurationView`、`ReviewEditorView`、`RelevantEditorView` | 由页面主滚动容器交互式收起 |
| SwiftUI 表单 Sheet | `ChapterBatchImportSheet`、`XMTagSelectionSheet` | 由 `Form` 或 scaffold 根滚动 owner 收起 |
| 连续全局搜索 | `GlobalSearchRootView` | 有意 `.never`；不是搜索页默认值 |
| UIKit 可编辑正文 | `RichTextEditorView`、`AIPromptTokenTextEditor` | 编辑器自身使用 `.interactive` |
| UIKit 浏览集合 | 书架与标签管理 collection host | 使用 `.onDrag` 快速收起 |
| 复杂键盘避让 | 书架集合协调器、笔记编辑器 | feature 级 frame/lifecycle 处理，不公共化 |

## 核心原则

### 系统优先

- SwiftUI 优先使用 `@FocusState`、`.focused`、`.searchFocused` 和 `.scrollDismissesKeyboard`。
- UIKit 滚动容器使用 `keyboardDismissMode`；具体输入控件使用自身 first responder API。
- SwiftUI 布局默认尊重 keyboard safe area；UIKit 需要跟随键盘布局时优先使用 `UIKeyboardLayoutGuide`。
- 系统已经提供手势物理时，不实现键盘位移、速度、阈值、spring 或触感。

### 一个焦点 owner，一个纵向滚动 owner

- 单字段使用 `FocusState<Bool>`；多字段使用可空、`Hashable` 枚举。`false` 或 `nil` 表示当前输入域没有焦点。
- 同一个字段不能同时由页面状态、全局 responder action 和 UIKit coordinator 竞争控制。
- 同一手势链只保留一个主要纵向滚动 owner。可增长多行输入由外层滚动时，内层不再独立滚动；固定高度编辑器确需内部滚动时，由编辑器承担键盘手势，外层不得同时抢占。
- 焦点表示输入目标，不等于软件键盘一定可见。硬件键盘、浮动键盘、交互式半程收起都可能让两者不同步。

### 直接、可逆、可恢复

- 正文编辑和长表单默认允许键盘随手指连续移动，并能在半程反向拖回。
- 提交或导航前主动结束焦点，避免键盘与后续转场竞争。
- 写入失败保留草稿和错误上下文；只有错误明确需要立即修正该字段时才恢复焦点。
- Reduce Motion 不关闭有助于理解因果的直接跟手，只移除额外自动运动或装饰动效。

## 场景决策矩阵

| 场景 | SwiftUI 默认 | UIKit 默认 | 关键约束 |
| --- | --- | --- | --- |
| 长表单、设置页、正文编辑 | 根 `ScrollView/List/Form` 使用 `.interactively` | 主 `UIScrollView` 使用 `.interactive` | 慢拖连续、允许反向，避免第二纵向 owner |
| 搜索结果、浏览列表 | 需要首拖立即看内容时使用 `.immediately` | `keyboardDismissMode = .onDrag` | 搜索词保留，收键盘不等于退出搜索 |
| 连续查询、必须持续输入 | 经产品验证后使用 `.never` | `.none` | 必须记录理由，并保留显式提交/取消路径 |
| 无滚动的单字段任务 | `FocusState<Bool>`，提交/取消时设为 `false` | 对具体 field 调用 `resignFirstResponder()` | 不给根容器增加 blanket tap gesture |
| 多字段表单 | 可空枚举 `FocusState`，Return 在字段间前进，最终提交时置 `nil` | delegate/first responder 链 | 顺序符合视觉与 Full Keyboard Access 顺序 |
| 多行或富文本编辑器内部滚动 | 编辑器或唯一外层滚动 owner 使用 `.interactively` | `UITextView.keyboardDismissMode = .interactive` | 先确定谁滚动，不能两边都处理同一 pan |
| 普通输入 Sheet | scaffold 根滚动使用 `.interactively` | UIKit 输入只在确有内部滚动时配置 | 键盘先收起，后续下拉才关闭 Sheet |
| 固定底栏或输入附件 | 使用系统 safe area 与 scaffold/safe-area 固定栏 | 约束到 `keyboardLayoutGuide` | 禁止固定键盘高度和设备特例表 |

`.automatic` 只在系统组件已经持有完整语义且运行结果经过验证时保留。不要因为它代码最少就跳过交互验收，也不要为了“统一”给所有滚动容器机械添加同一个 mode。

## SwiftUI 焦点管理

单字段：

```swift
@FocusState private var isFieldFocused: Bool

TextField("名称", text: $name)
    .focused($isFieldFocused)
    .submitLabel(.done)
    .onSubmit(submit)

private func submit() {
    guard canSubmit else { return }
    isFieldFocused = false
    // 焦点结束后进入现有业务提交路径。
}
```

多字段：

```swift
private enum Field: Hashable {
    case title
    case detail
}

@FocusState private var focusedField: Field?
```

- 每个字段绑定唯一枚举 case；不得把同一 case 绑定给多个输入控件。
- Return 键语义通过 `submitLabel` 和 `onSubmit` 表达：中间字段前进，最后字段提交或结束焦点。
- 自动聚焦不是页面默认。确实能加速任务时，等待视图进入稳定层级后再设置焦点，并取消可能在离场后重新抢焦点的延迟 Task。
- 关闭、取消、切换模式、push 或 dismiss 前先清空焦点。若系统转场仍与当前更新周期竞争，可在清空焦点后 `Task.yield()` 一次，再执行导航；不能写固定毫秒延迟模拟系统时序。
- SwiftUI 页面不得新增通用 `UIApplication.shared.sendAction` 或全局 `hideKeyboard()` 扩展。页面已持有字段时，焦点状态就是程序化结束输入的 owner。

## 滚动收起模式

### `.interactively`

适用于编辑、阅读与滚动连续发生的页面。验收标准是键盘跟随手指、半程可逆、松手后按系统速度完成，不在手势结束后突然跳走。

### `.immediately` / `.onDrag`

适用于搜索结果或浏览集合：用户一开始滚动就表明要查看内容，继续保留大面积键盘的价值较低。收起只结束输入焦点，不应自动清空 query、退出搜索模式或丢失筛选结果。

### `.never` / `.none`

只用于连续修正查询、滚动候选时必须保持输入会话的场景。调用方必须证明：

1. 滚动时保持键盘确实提升主任务效率。
2. 内容在键盘存在时仍可达。
3. 用户有明确的 Search、Done、Cancel、关闭或导航路径结束输入。
4. 该行为已在窄屏、横屏和辅助功能字号下验证。

## Sheet 的两级手势

输入型 Sheet 的默认因果关系是：

1. 键盘显示时，下滑由内容滚动接管并交互式收起键盘，Sheet 顶边保持稳定。
2. 键盘完全隐藏后，后续独立下滑恢复系统 Sheet 的正常关闭。

实现规则：

- `XMSheetScaffold` 继续是导航、根滚动和固定栏 owner；页面把 `.scrollDismissesKeyboard(.interactively)` 施加在 scaffold 结果上，不在内容槽再放第二个 `ScrollView`。
- 默认保留 `.presentationContentInteraction(.automatic)`。只有 Simulator 或录屏稳定复现“键盘显示时 Sheet 抢先移动/缩放”后，才在该 feature 内根据真实键盘呈现状态切换为 `.scrolls`，键盘完全隐藏后恢复 `.automatic`。
- `FocusState` 不能单独代表交互式拖动中的真实键盘位置。若手势优先级决策必须依赖键盘是否已经完全离屏，先验证纯 SwiftUI 是否足够；仍不足时，在最窄 UIKit bridge 内读取系统键盘布局状态，不新增 App 级 KeyboardManager。
- `.interactiveDismissDisabled` 只服务保存中、显式业务锁或未保存退出保护。它不能解决键盘手势优先级，也不能用来制造“第一次只能收键盘”。
- 键盘出现时关闭按钮仍保持可用，并继续执行页面已有的任务取消、草稿处理和 dismiss 逻辑。

### 提示词优化 Sheet 的现有特例

`AIPromptOptimizationSheet` 当前为已录屏验证的 feature-private 方案：外层 scaffold 使用 SwiftUI 交互式收起；UIKit 多行编辑器使用 `.interactive`；真实键盘呈现期间 presentation 优先 `.scrolls`，隐藏后恢复 `.automatic`；内外 pan 的等待关系和 `keyboardLayoutGuide` 检查只用于解决该页已复现的嵌套手势竞争。

该实现不是可复制模板。其他 Sheet 必须先走系统默认与单一滚动 owner，只有出现相同复现、相同 owner 冲突和相同验收结论后，才讨论公共化。

## 搜索场景

- 导航栏搜索优先 `.searchable`，需要程序化控制时使用 `.searchFocused`；系统已经持有的 Cancel、提交和焦点行为不重复桥接。
- 内容区常驻搜索使用 `XMInlineSearchField`。组件持有字段焦点，父级页面持有结果滚动与 dismissal mode。
- 需要 UIKit 原生搜索栏时使用 `XMSystemSearchBar`。其 coordinator 负责 Binding 与具体 `UISearchTextField` first responder 双向同步，并在 dismantle 时取消待执行焦点请求。
- 点击清除通常保留焦点以便继续输入；提交是否收起键盘由结果任务决定；退出搜索才同时结束焦点和搜索呈现状态。
- 不使用全局 responder action 弥补 `.searchable` 或自定义搜索状态 owner 不清晰的问题。

## UIKit 与 SwiftUI 桥接

- 可编辑 `UIScrollView/UITextView` 使用 `.interactive`；以浏览结果为主的 `UICollectionView` 可以使用 `.onDrag`。
- 程序化结束输入时优先调用已知 `UITextField/UITextView/UISearchTextField` 的 `resignFirstResponder()`。
- 只有 UIKit 容器确实不知道哪个后代持有焦点，且作用域被限制在该容器时，才允许 `containerView.endEditing(true)`。不得对 window 或 App 根视图做常规广播。
- `UIViewRepresentable` coordinator 必须双向同步 SwiftUI 焦点与 UIKit first responder；延后 `becomeFirstResponder()` 时使用可失效请求，避免旧请求在快速切换或离场后重新唤起键盘。
- `dismantleUIView` 或 owner 销毁时取消焦点任务、移除 delegate/observer，并让当前具体输入控件 resign。
- 中文、日文等组合输入期间 `markedTextRange` 非空，SwiftUI 外部状态不得反向替换 UIKit 正文；等待组合完成后再投影或格式化。

## 键盘避让与固定操作

### SwiftUI

- 让页面内容尊重系统 keyboard safe area；需要全屏背景时只让背景忽略 safe area，不让输入内容和主操作一起忽略。
- 固定底栏使用已有页面骨架、`safeAreaInset`/当前系统 safe-area 能力或 `XMSheetScaffold.bottomBar`，不监听键盘高度后手工 offset。
- `.ignoresSafeArea(.keyboard)` 只允许真正需要键盘覆盖内容、且另有可靠可达路径的专项界面。普通表单不能用它保持视觉位置。
- 键盘弹出后，当前字段、邻近错误和唯一主操作必须仍可通过系统布局或唯一滚动容器到达。

### UIKit

- 固定在键盘附近的控件优先约束到 `view.keyboardLayoutGuide`；需要跟随浮动/分离键盘时按场景配置 `followsUndockedKeyboard` 与 tracking constraints。
- 不用屏幕高度减键盘 `minY` 作为所有 window、Stage Manager、浮动键盘和硬件键盘的统一真相。
- 只有既有 UIKit collection inset 或业务生命周期无法由 layout guide 表达时才监听 frame notification。实现必须：
  - 把 screen frame 转换到当前 window，再转换到 host 坐标系。
  - 计算真实交集并扣除系统 `adjustedContentInset`，避免重复避让。
  - 使用通知携带的 duration、curve，并支持 begin-from-current-state 与用户交互。
  - 处理无交集、硬件键盘、浮动/分离键盘、窗口尺寸变化和 observer 释放。

`BookshelfCollectionKeyboardAvoidanceCoordinator` 满足集合 inset 的窄边界；`NoteEditorView` 的键盘通知还驱动编辑器折叠时机。没有相同业务状态机时不得复制这两种实现。

## 提交、错误与导航生命周期

- 主操作先校验，再结束焦点，再进入已有异步请求；写入开始立即防止重复触发。
- 失败保留字段值、选择、滚动位置和可修复错误。只有错误与具体字段绑定、恢复焦点不会遮挡用户正在阅读的错误时，才在稳定更新周期后重新聚焦。
- 成功后由现有业务状态执行导航或 dismiss；不为了等键盘写固定 delay。
- 关闭或离场要取消尚未执行的自动聚焦请求，防止底层页面或下一页面意外弹出键盘。
- 焦点结束可能触发 autocorrection、自动补全或 Binding 最终回写；Presented state、草稿 owner 和 ViewModel 不能在这些回写完成前被无条件销毁。

## 输入语义与显式结束路径

- 按内容选择 `keyboardType`、`textContentType`、大小写、自动更正和拼写检查，不为“界面统一”关闭系统输入辅助。
- `submitLabel` 使用真实动作语义，例如 `next`、`search`、`done`、`go`；不能所有字段统一写成 Done。
- 数字键盘等没有 Return 键的输入，必须存在可达的页面级提交、取消或关闭路径。只有页面没有其它清晰结束入口时才考虑 feature-private keyboard toolbar，不能把 toolbar“完成”设为所有字段默认。
- Placeholder 只在空值时可见，不能承载输入后仍必须记住的关键约束；是否需要常驻标签由字段语义和用户要求决定，不由键盘规范强制增加。

## 可访问性与多设备验证

- 文本输入焦点与 VoiceOver/Full Keyboard Access 焦点是不同系统。结束文本焦点不能把辅助功能焦点强行跳到无关控件。
- 多字段的视觉顺序、源码顺序、Return 前进顺序和 Tab 顺序保持一致。
- 硬件键盘连接时软件键盘可能不出现，但焦点、提交、Escape/Cancel 和底部操作仍需工作。
- iPad 验证 docked、floating、undocked/split keyboard；不要假设键盘始终占满屏幕底部宽度。
- Dynamic Type、横屏与窄窗口下，当前字段和操作不得因键盘安全区压缩而不可达。
- Reduce Motion 下保留系统直接跟手，不叠加自定义 spring、回弹或自动位移。

## 禁止模式

- 在 SwiftUI 新增 App 级 `hideKeyboard()`、`UIApplication.sendAction` 或 responder 广播。
- 给页面根容器添加覆盖所有子控件的 `onTapGesture` 收键盘，导致 Button、选择、滚动或文本选区竞争。
- 同一页面同时让内层 `TextEditor/UITextView` 与外层 `ScrollView` 争夺纵向 pan，却没有明确 owner。
- 未经产品理由使用 `.never`，或把 `.interactive` 机械应用到所有搜索和浏览列表。
- 用 `.interactiveDismissDisabled` 解决键盘收起问题。
- 手写 drag gesture、键盘 offset、阈值、动画曲线、spring 或触感模拟系统键盘。
- 把 `FocusState == true` 当作“软件键盘当前完整显示”的可靠判断。
- 普通 SwiftUI 页面监听键盘 frame 并硬编码 bottom padding。
- 为访问底层 UIKit 视图引入 introspection，而当前公开 SwiftUI/UIKit API 已能表达需求。
- 在 `markedTextRange` 存在时重写正文，破坏中文联想和组合输入。

## 验收清单

只验证页面真实存在的状态，但所有新建或修改输入页面至少回答以下问题：

### 焦点与提交

- 初始是否应该自动聚焦；离场任务是否可能重新抢焦点。
- 单字段 Bool 或多字段枚举是否为唯一 owner。
- Return、主操作、取消、关闭和导航是否按语义结束或移动焦点。
- 异步提交是否只触发一次；失败是否保留草稿并允许继续编辑。

### 手势与滚动

- 慢速下滑时键盘是否连续跟手；半程反向是否可恢复；松手是否无跳变。
- 搜索/浏览是否需要首拖立即收起，还是有证据保持键盘。
- 是否只有一个纵向滚动 owner；从输入框内部和外部空白区开始手势都要验证。
- Sheet 中键盘显示时是否避免抢先移动、露出底层或误关闭；键盘隐藏后是否仍能正常下拉关闭。

### 布局与输入法

- 当前字段、错误和主操作在默认/辅助功能字号、横屏、窄窗口下是否可达。
- 中文联想、自动更正、粘贴、选择和撤销是否不被状态回写破坏。
- 硬件键盘及 iPad docked/floating/undocked/split keyboard 是否正确。

### 可访问性与动效

- VoiceOver 朗读、焦点顺序、Full Keyboard Access Tab 顺序和提交语义是否正确。
- Reduce Motion 下是否仍保留直接跟手，且没有额外自动运动。
- 录屏验收手势时同时记录设备、系统版本、方向、键盘类型和起始触点。

## 迁移优先级

本规范落地不授权批量修改现有页面。后续触及输入页面时按以下顺序收敛：

1. **高优先级**：全局 responder action、根视图 blanket tap、手算键盘高度、固定 keyboard padding、自定义键盘拖拽。
2. **高优先级**：键盘、Sheet 和嵌套滚动相互抢手势，或输入/主操作被遮挡的可复现问题。
3. **中优先级**：多字段没有明确 FocusState owner、离场后重新抢焦点、异步失败丢失输入上下文。
4. **中优先级**：`.never`、`.immediately`、`.onDrag` 与真实搜索/浏览任务不匹配。
5. **保持现状**：系统默认已经满足任务、没有手势冲突且完整通过验收的页面；不为了代码外观一致机械改写。

只有至少两个独立生产场景证明相同根因、相同 owner 边界和相同修复模式后，才评估公共 modifier、coordinator 或组件。单个 Sheet 的手势修复继续保留 feature-private。

## Apple 平台校验入口

- [scrollDismissesKeyboard(_:)](https://developer.apple.com/documentation/swiftui/view/scrolldismisseskeyboard%28_%3A%29)
- [Direct and reflect focus in SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10023/)
- [The SwiftUI cookbook for focus](https://developer.apple.com/videos/play/wwdc2023/10162/)
- [UIScrollView.KeyboardDismissMode.interactive](https://developer.apple.com/documentation/uikit/uiscrollview/keyboarddismissmode-swift.enum/interactive)
- [UIKeyboardLayoutGuide](https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide)
- [Adjusting your layout with keyboard layout guide](https://developer.apple.com/documentation/uikit/adjusting-your-layout-with-keyboard-layout-guide)
- [Keep up with the keyboard](https://developer.apple.com/videos/play/wwdc2023/10281/)
- [PresentationContentInteraction](https://developer.apple.com/documentation/swiftui/presentationcontentinteraction)
- [Text fields HIG](https://developer.apple.com/design/human-interface-guidelines/text-fields)
- [Text views HIG](https://developer.apple.com/design/human-interface-guidelines/text-views)

## 社区风险参考

- [SwiftUI Introspect](https://github.com/siteline/swiftui-introspect)：说明 introspection 依赖底层视图结构并需要显式适配新系统版本，因此只作为公开 API 无法表达时的最后手段。
- [Point-Free：Composable navigation beta 讨论](https://github.com/pointfreeco/swift-composable-architecture/discussions/1944)：提供 Sheet 关闭、焦点清空、自动补全和 Binding 最终回写顺序的社区实证。它用于提醒生命周期风险，不作为 XMNote 引入 TCA 或固定延迟的依据。

这些入口用于实现时重新核对当前平台事实；本文件不复制 Apple 手册，也不保证未来 SDK 行为不变。
