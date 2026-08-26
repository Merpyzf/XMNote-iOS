# Services/
> L2 | 父级: /CLAUDE.md

网络基础设施与业务服务层。包含 Alamofire 封装、WebDAV 协议操作与备份业务逻辑。

## 成员清单

- `NetworkClient.swift`: Alamofire Session 封装，支持 Basic Auth 与无认证两种模式
- `NetworkError.swift`: 网络错误语义枚举（unauthorized/notFound/serverError 等）
- `HTTPMethod+WebDAV.swift`: Alamofire HTTPMethod 扩展，添加 PROPFIND/MKCOL 方法
- `WebDAVClient.swift`: WebDAV 协议操作客户端（PROPFIND/MKCOL/PUT/GET/DELETE）
- `BackupService.swift`: 数据库、Android 兼容偏好与 iOS 可选 sidecar 的统一归档和恢复内核
- `AIConfigurationStore.swift`: 完整 AI 配置与两家密钥的 UserDefaults v2 原子存储及旧 Keychain 迁移边界
- `IOSUserDefaultsBackupCoordinator.swift`: iOS UserDefaults 类型化白名单 sidecar 的导出、校验与整组恢复协调器
- `OpenAICompatibleClient.swift`: OpenAI-compatible SSE 与非流式文本生成客户端
- `BookRemoteSearchService.swift`: 在线书籍检索与结果映射服务
- `NoteSpeechController.swift`: 书摘编辑语音识别会话控制器

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
