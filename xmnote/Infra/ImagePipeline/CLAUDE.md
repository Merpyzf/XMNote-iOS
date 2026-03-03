# ImagePipeline/
> L2 | 父级: ../CLAUDE.md

图片加载基础设施子模块，负责统一 Nuke 管线配置、请求构造与非 UI 下载抽象。

## 成员清单

- `XMImagePipeline.swift`: 应用级 Nuke 管线工厂（缓存/超时/并发策略）
- `XMImageRequestBuilder.swift`: 统一图片请求构造（URL 校验、防盗链请求头、GIF 探测）
- `XMCoverImageLoader.swift`: Data 层图片下载抽象（`XMCoverImageLoading` + `NukeCoverImageLoader`）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
