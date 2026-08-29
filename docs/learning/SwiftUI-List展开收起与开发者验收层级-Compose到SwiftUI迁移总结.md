# SwiftUI List 展开收起与开发者验收层级 - Compose 到 SwiftUI 迁移总结

更新日期：2026-08-29

## 背景与边界

本轮从录屏中的 `List` 行内详情展开收起入手，对照[《用自定义 Layout 化解 SwiftUI List 的行高与间距跳变》](https://fatbobman.com/zh/posts/taming-row-height-and-spacing-jumps/)及其[完整示例](https://gist.github.com/nikolaknez/4b1f049c3500785f2869b3b3a1c6123d)，在 Debug 目录建立 `AnimatedPresencePrototype` 与 `CollapseAwareVStackPrototype`，并接入 Sheet Catalog 做原生/候选方案实证。

这不是生产公共组件交付。当前证据只证明候选方案在一个 Debug 验收场景局部成立，尚未证明两个独立生产场景具有相同根因、状态边界和修复模式，因此：

- 原型继续位于 `xmnote/Views/Debug/Prototypes/`。
- 类型继续使用 `Prototype` 后缀。
- 不登记 `component-catalog.json`，不创建生产组件指南。
- 不迁移阅读日历设置、桌面网页设置或其他生产页面。

## 问题应拆成三条时间线

### 1. 内容生命周期

外部状态在开始收起时通常已经变成 `nil` 或 `false`。如果渲染内容直接绑定这个状态，内容会在父级高度动画开始前被销毁，动画只剩空壳。

候选组件把外部 `value` 与内部 `displayValue` 解耦：展开时立即接收新值，收起时保留旧值，直到高度归零后才清理。每次状态变化递增 generation，完成回调只有在 generation 与当前外部状态仍匹配时才允许清理，避免快速反向操作被旧回调误伤。

### 2. 可见高度

直接给文字逐帧传入更小的高度 proposal，会让文字参与压缩、截断或基线重排，视觉上像被挤扁。候选组件改为：

- 子内容始终按固有高度测量和放置。
- 自定义 `Layout` 只向父级报告逐帧变化的可见高度。
- 外层通过裁切隐藏超出可见高度的部分。
- `onGeometryChange` 只接收有限、非负的固有高度，并用最近目标高度而非动画中间值去重，避免测量反馈循环。

首次以展开状态挂载时直接落到固有高度，不重播入场动画。这一点对 `List` 滚动回收后重建行尤其重要；展开状态由详情页的稳定目标 ID 集合持有，不寄存在可能被回收的行视图中。

### 3. 相邻间距

标准 `VStack` 的间距不会因为某个子内容高度正在趋近零就自动按同一进度收缩。只动画高度会产生“内容先消失、空隙再跳掉”的二段感。

`CollapseAwareVStackPrototype` 通过可动画的 presence progress 逐帧缩放相邻间距，使高度与间距共享同一时间线。若一个或一组已收起子内容位于两个可见兄弟之间，布局还会逐步补回这两个新相邻兄弟应有的正常间距，避免最终完全贴合。

## 状态与可访问性不变量

- Reduce Motion 下结构变化立即落位，不保留位移或高度补间。
- 开始收起后立即关闭命中与辅助功能暴露，而不是等内容节点最终销毁。
- 打开生产 Sheet 与展开实现详情是两个独立操作、两个独立 VoiceOver 焦点。
- 展开按钮提供“已展开/已收起” value、动态 hint 和至少 44pt 的有效点击区域。
- 辅助功能字号下，目标摘要与打开按钮由横向布局改为纵向布局，避免压缩目标名称。

## 开发者验收页的信息层级

Sheet Catalog 的主任务是打开真实生产 Sheet，查看实现证据只是排查辅助。因此页面按以下层级组织：

1. 一级摘要：目标 owner、用途、生产快照状态。
2. 一级操作：始终可见的“准备中 / 不可用 / 打开”按钮，折叠状态也能直接操作。
3. 二级详情：生产数据与调用配置、当前 iOS 呈现参数、Android 类比与源码证据。

“原生 / 平滑基建”分段选择只控制二级详情的展开方式，不得影响一级打开入口。两种模式共享同一组展开 ID，所以模式切换、滚动复用与从生产 Sheet 返回后都不会丢失排查现场。

这个层级原则可以复用到其他开发工具：执行主任务的操作不能被诊断信息折叠；证据可以按需展开，但不能成为完成主任务的前置步骤。

## Android Compose 对照思路

跨端可复用的是状态与层级原则，不是具体布局 API。Compose 的 `AnimatedVisibility`、`animateContentSize` 与 SwiftUI 自定义 `Layout` 处在不同运行时，不应机械互译。

```kotlin
@Composable
fun SheetTargetList(
    targets: List<SheetTarget>,
    expandedIds: Set<String>,
    onExpandedChange: (String, Boolean) -> Unit,
    onOpen: (SheetTarget) -> Unit
) {
    LazyColumn {
        items(targets, key = { it.id }) { target ->
            Column {
                TargetSummary(target)

                OutlinedButton(onClick = { onOpen(target) }) {
                    Text("打开")
                }

                TextButton(
                    onClick = {
                        onExpandedChange(target.id, target.id !in expandedIds)
                    }
                ) {
                    Text(if (target.id in expandedIds) "收起实现详情" else "展开实现详情")
                }

                AnimatedVisibility(visible = target.id in expandedIds) {
                    TargetImplementationDetails(target)
                }
            }
        }
    }
}
```

Compose 侧同样应由列表上层按稳定 ID 持有展开状态，并把“打开”与“实现详情”拆成独立操作。至于高度、裁切和间距是否需要自定义动画容器，必须根据 Compose 端真实录屏、布局 owner 与运行时测量结果重新判断，不能因为 iOS 命中该问题就预设 Android 也需要同一基建。

## 本阶段验证与限制

本轮在 Parallel iOS 专属 Simulator 上完成以下运行态观察：

- 折叠状态可直接打开正确的生产 Sheet，返回后页面状态保留。
- 原生与平滑模式共用展开状态，切换模式不会重置详情。
- 默认字号和辅助功能字号下，一级打开操作与二级详情操作保持独立焦点和有效点击区域。
- 平滑模式下，长内容反复展开收起时按固有尺寸裁切，后续内容随高度与间距连续移动。
- 构建与运行通过，未执行 `ai-test`。

代码核对确认快速反向操作由 generation 保护，不让旧 completion 清理新内容。本轮没有强制注入生产快照失败，也没有在系统设置中切换 Reduce Motion；失败文案/禁用状态与 Reduce Motion 降级已从代码路径核对，但仍属于下一轮运行矩阵中的待观察项。`List` 为维持可见区域产生的正常滚动锚定也不属于本组件消除范围。

## 晋升为生产基建前必须补齐

- 至少两个独立生产场景，证明根因、状态边界和修复模式一致。
- 明确外部状态 owner、写入点、列表复用与首次挂载时机。
- 覆盖快速反向、多项同时展开、动态内容换高、大字体、Reduce Motion、VoiceOver 与失败恢复。
- 提供与风险匹配的 Preview/测试和真实运行证据。
- 晋升后再命名为 `XMAnimatedPresence`、`XMPresenceVStack`，归位 `UIComponents`，登记机器目录并补生产组件指南。

在这些条件满足前，复制原型到生产页面或把 Debug 成功直接解释为公共规范，都会越过设计系统的证据边界。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
