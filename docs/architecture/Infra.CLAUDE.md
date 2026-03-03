# Infra/
成员清单
- RepositorySupport/ObservationStream.swift: ValueObservation 到 AsyncThrowingStream 桥接。
- ImagePipeline/XMImagePipeline.swift: Nuke 图片管线工厂（缓存/超时/并发配置）。
- ImagePipeline/XMImageRequestBuilder.swift: 图片请求构造器（URL 归一化、防盗链请求头、GIF 探测）。
- ImagePipeline/XMCoverImageLoader.swift: 非 UI 场景图片下载抽象（XMCoverImageLoading + Nuke 默认实现）。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
