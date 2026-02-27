# Services/
> L2 | 父级: /CLAUDE.md

网络基础设施与业务服务层。包含 Alamofire 封装、WebDAV 协议操作与备份业务逻辑。

## 成员清单

- `NetworkClient.swift`: Alamofire Session 封装，支持 Basic Auth 与无认证两种模式
- `NetworkError.swift`: 网络错误语义枚举（unauthorized/notFound/serverError 等）
- `HTTPMethod+WebDAV.swift`: Alamofire HTTPMethod 扩展，添加 PROPFIND/MKCOL 方法
- `WebDAVClient.swift`: WebDAV 协议操作客户端（PROPFIND/MKCOL/PUT/GET/DELETE）
- `BackupService.swift`: 数据备份与恢复业务逻辑编排

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
