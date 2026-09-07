# 按钮样式与主操作

本参考决定按钮的视觉层级、交互式 Liquid Glass 适用边界与状态验收。提交位置和 Sheet 骨架由 [业务 Sheet](sheets.md) 决定，退出含义由 [导航与退出语义](navigation-and-dismissal.md) 决定，配色和对比度由 [颜色、表层与材质](color-surfaces-and-material.md) 决定；不要用材质偏好改变这些语义。

## 产品选择与平台依据

XMNote 已选择交互式 Liquid Glass 作为符合条件的独立浮动主操作、Sheet 底部主操作的默认表达。这是用户确认的产品选择，不是 Apple 要求所有主按钮采用某一条 modifier 链。

- Apple 将 Liquid Glass 定位为浮在内容之上的功能控制层，要求克制使用，不将其铺到内容层。是否为主动作和是否适合玻璃是两个判断，前者不能代替后者。[Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials)
- Apple 支持用 `glassEffect` 与 `interactive(_:)` 构建响应触摸和指针的自定义组件；系统按钮样式同样提供原生玻璃能力。不得声称 `.glassProminent` 没有交互、已弃用或不符合 HIG。[自定义 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[GlassProminentButtonStyle](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle)
- 标准控件和 toolbar 继续优先交给系统适配。规范以 iOS 26 为基线，引用 HIG 时核对平台章节，不把 watchOS 的全宽按钮或 visionOS 的形状、尺寸规则移植到 iOS。[Buttons HIG](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Toolbars HIG](https://developer.apple.com/design/human-interface-guidelines/toolbars)

## 先定角色与承载层，再选样式

先查 catalog 和真实 owner；已有 canonical 专项按钮时遵守其合同。没有匹配入口时，才按下表使用原生控件和功能内组合：

| 场景 | 默认表达 | 不可类推的边界 |
| --- | --- | --- |
| 位于独立功能控制层的浮动主操作，或已按 Sheet 规则确定需要的底部主操作 | 染色的 `.regular.interactive()` 玻璃表面；全宽文字主按钮默认胶囊 | 不因“主操作”就新增浮层、固定栏或玻璃，不复制某页尺寸 |
| Sheet 顶部完成、取消及导航栏操作 | scaffold 与系统 toolbar 外观 | 不额外包裹 glass，不为新样式把确认下移或复制到内容尾部 |
| 普通列表行、表单行、内容内辅助动作 | 系统或中性样式 | 可点击、动作重要、位于 Sheet 内，都不能单独构成加玻璃的理由 |
| 删除及危险动作 | 原生 destructive role 与对应反馈语义 | 不套品牌绿色主操作，不把危险动作伪装成推荐选择 |
| 已有 canonical 专项按钮 | 当前 owner 持有的样式与状态 | 不在调用处覆盖内部材质；确需迁移时单独审查 owner |

- 同一任务面通常只保留一个同权主按钮；次级动作靠中性样式降级，不靠缩小点击区制造层级。菜单、Toggle、Picker 和选择标记继续使用各自语义，不批量套此样式。
- `.glass`、`.glassProminent` 仍是系统上下文及有明确理由的替代方案。适用场景不满足、已有 canonical 合同应保留，或经对照验证系统样式更适配时，说明原因并使用替代；不能只凭“原生优先”忽略已确认的项目默认。
- 新规则只指导当前授权范围内的新增或修改，不触发全项目迁移。玻璃也不替代 [安全区与系统滚动边缘](safe-area-and-system-scroll-edge.md) 的固定栏可读性处理。

## 实现合同

可用主操作的核心材质表达为：

```swift
.glassEffect(
    .regular.tint(Color.appTint).interactive(),
    in: .capsule
)
```

这只是材质片段，不是含有完整状态、尺寸和配色的可复制组件：

- 保留真实 `Button`。可使用 `.buttonStyle(.plain)` 配合玻璃，也可由功能内 `ButtonStyle` 对 `configuration.label` 配置玻璃；两者是实现选择，不要求逐字一致。不用 `onTapGesture` 替代按钮激活语义。
- 先完成标签排版、有效尺寸、内边距和可命中轮廓，再应用玻璃。点击区覆盖整个可见按钮，不能出现“玻璃变大、可点击文字仍很小”。尺寸继续消费现有 Typography、Spacing 和 `InteractionMetrics.minimumTouchTarget`，不把导入页的 50pt 或某个 padding 固化为全局标准。
- 每个按钮只保留一套玻璃表面；不在 `.glass/.glassProminent` 外再套 `glassEffect`，也不覆盖系统 toolbar 已持有的玻璃。多个玻璃确有融合或共享采样关系时才核对 `GlassEffectContainer`，不机械给单按钮加容器。
- 不自行叠加按压缩放、弹跳、渐变、重阴影或触感来模拟液态效果。保持系统响应，不引入阻塞点击、等待动画结束或重复提交的门闩。
- 标签使用结果明确的动词，保持 Dynamic Type 和长文案可读性；图标按钮补充实际动作的可访问性名称，不朗读图标文件名。按钮文案和元数据不使用中心圆点拼接，按信息关系分行或留白。

## 配色、状态与可访问性

- 品牌 tint 用于主操作的玻璃表面，不同时染绿标签。保留系统 owner；自定义品牌主操作通过 `primaryActionForeground` 消费 `onBrandForeground` 的普通不透明纯白默认与辅助功能适配，详见 [品牌表面前景](color-surfaces-and-material.md#品牌表面前景)。这不推广到任意绿底，也不以 token 名称为对比度合格证明。
- 染色玻璃不是实心填充。原有实心按钮或另一种玻璃样式的截图测量不能套用；按实际背景、外观和状态重新测量，遵守 [颜色配对与对比度要求](color-surfaces-and-material.md#操作按钮前景背景配对)。不达标时报告真实 owner 与最小调整方案，不能擅自硬编码黑白前景或修改全局颜色来掩盖问题。
- 禁用同时停止业务激活和玻璃交互，并呈现可辨、可读的禁用状态；`interactive(false)` 不等于 `.disabled(true)`，二者不能互相替代。
- 加载期间防止重复提交，文字和 spinner 原位表达当前动作，避免按钮宽高突变；失败恢复可操作并保留输入。业务 phase、异步任务和错误恢复留在页面 owner，不进入纯视觉样式。
- 尊重减少动态效果、降低透明度和增强对比度设置，不通过自制动画或背景抵消系统适配。减少运动不等于取消一切按压反馈；不能机械复制 `.interactive(!reduceMotion)` 后不检查响应。必要的低运动反馈交给系统或专项动效审查，避免无反馈按钮。[Liquid Glass 适配指导](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

## 局部参考与公共化边界

[NoteImportPrimaryButtonStyle](../../../../xmnote/Views/Personal/DataImport/NoteImportPrimaryButtonStyle.swift) 是导入流程的局部实现，用户已确认其交互效果偏好；同一导入流程的多个调用不自动成为独立跨功能证据。

本规范批准的是适用场景下的设计选择，不赋予该类型 canonical 身份，不授权其他功能直接依赖它或把它移入 `UIComponents`。它当前的前景色、尺寸、Reduce Motion 分支和每个承载位置仍需分别验证，不能宣称已经全面通过 HIG 验收。公共组件继续遵守 [组件准入](components-and-interaction.md#公共组件准入) 与 [证据等级](evidence-and-review.md)。

## 验证与前向审查

实际页面按风险验证浅色、深色、不同底层内容、默认与辅助功能字号、VoiceOver、正常按压和移出取消、禁用、加载与失败恢复，以及减少动态效果、降低透明度、增强对比度。静态截图不能证明触摸动态已验收；记录设备、系统版本、状态和证据范围。

以下场景必须能得到明确结论：

| 输入场景 | 应得结论 |
| --- | --- |
| 普通编辑 Sheet 顶部“完成” | 保留系统确认入口，不下移、不加第二层玻璃 |
| 已确定需要的 Sheet 底部“导入”，无匹配 canonical 按钮 | 使用功能内交互式玻璃主按钮，并验证状态与配色 |
| 表单行“查看帮助”或普通列表动作 | 保留系统或中性样式，不玻璃化 |
| 删除内容的确认动作 | destructive 语义，不品牌化 |
| 开启减少动态效果后按下主按钮 | 降低非必要运动，仍有可感知反馈 |
| 使用现有 token 但实测对比度不足 | 不放行，不用旧截图或 token 名称替代验证 |
| 三联记住密码采用已确认的白绿配色 | 仅记录颜色参考中的局部例外，不向按钮或其他选择器传播，不宣称达标 |

仅修改本 Skill 时，执行 Skill Creator 结构校验、相对链接检查及差异检查，并人工前向审查上述场景；不因此运行 App 测试、Xcode 构建或整改生产页面。
