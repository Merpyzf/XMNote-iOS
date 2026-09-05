---
name: ios-motion-design
description: XMNote 动效设计的兼容入口。手势、转场、spring、Lottie、触感和 Reduce Motion 的设计或评审统一读取 xmnote-design-system 的动效专题，保留 Apple 平台基线与 Airbnb 产品视角。
---

# iOS Motion Design — 兼容入口

动效设计已合并到 `xmnote-design-system`，本入口保留原有调用方式，不独立维护规则。

1. 读取 [XMNote Design System](../xmnote-design-system/SKILL.md)，遵守其任务模式、权限与设计真相。
2. 读取 [动效与手势](../xmnote-design-system/references/motion.md)，再按当前问题选择 Apple 原则或 Airbnb 产品视角；无需加载无关的静态设计参考。
3. 已读且仍有效的主 Skill、工作流和证据可以复用，不因兼容入口重复发现、验证或询问。

动效规则和参考的主维护目录为 `.codex/skills/xmnote-design-system/references/`，其中的相对引用均按该目录解析。本目录旧参考路径仅作转发，不同时维护两套内容。主文件缺失时报告具体阻塞，不静默恢复旧规则；继续独立的已授权工作。
