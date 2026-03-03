# Infra/
> L2 | 父级: /CLAUDE.md

底层桥接与仓储支持设施。提供 Repository 实现所需的通用工具。

## RepositorySupport/

- `ObservationStream.swift`: GRDB ValueObservation 到 AsyncThrowingStream 桥接器，供 Repository 实现实时数据监听

## ImagePipeline/

- `XMImagePipeline.swift`: Nuke 图片管线工厂（超时、缓存、并发策略）
- `XMImageRequestBuilder.swift`: 图片请求构造器（URL 归一化、防盗链请求头、GIF 探测）
- `XMCoverImageLoader.swift`: 非 UI 场景图片下载抽象（`XMCoverImageLoading` + Nuke 默认实现）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
