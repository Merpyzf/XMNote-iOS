/**
 * [INPUT]: 依赖系统 dnssd、Darwin 网络接口索引、已监听的 HTTP 端口与当前局域网 IPv4 端点
 * [OUTPUT]: 对外发布固定 `xmnote.local` A 记录与 `_http._tcp` 服务，并区分可回退错误和本地网络权限拒绝
 * [POS]: Services 的固定局域网域名适配层，只公告现有 socket，不创建第二个 listener
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Darwin
import Foundation
import dnssd

/// 固定局域网域名的可观察发布结果；普通失败允许网页服务继续使用 IP 地址。
nonisolated enum BonjourServicePublisherEvent: Equatable, Sendable {
    case published(url: URL)
    case unavailable(message: String)
    case policyDenied(message: String)
}

/// 交给系统 DNS-SD 后端的单条 IPv4 地址记录。
nonisolated struct BonjourIPv4Record: Equatable, Sendable {
    let interfaceIndex: UInt32
    let addressData: Data
}

/// 固定域名和 HTTP 服务公告所需的不可变输入，便于在不触发真实组播的情况下验证编码。
nonisolated struct BonjourServiceRegistrationRequest: Equatable, Sendable {
    let hostname: String
    let serviceName: String
    let serviceType: String
    let domain: String
    let networkPort: UInt16
    let url: URL
    let addressRecords: [BonjourIPv4Record]
}

/// 系统后端的最小事件面，隔离 C 回调并允许测试替身驱动发布生命周期。
nonisolated enum BonjourServiceBackendEvent: Equatable, Sendable {
    case addressesPublished
    case addressRegistrationFailed(code: Int32)
    case serviceRegistrationFailed(code: Int32)
}

/// 可注入的 DNS-SD 启动边界；生产实现使用系统 mDNSResponder，测试实现只记录请求并主动回调。
nonisolated struct BonjourServicePublisherBackend {
    typealias Cancellation = @MainActor @Sendable () -> Void
    typealias EventHandler = @Sendable (BonjourServiceBackendEvent) -> Void
    typealias Start = @MainActor @Sendable (
        BonjourServiceRegistrationRequest,
        @escaping EventHandler
    ) throws -> Cancellation

    let start: Start

    /// 保存后端启动闭包；调用和取消均由 MainActor 的发布 owner 发起。
    init(start: @escaping Start) {
        self.start = start
    }

    static let system = BonjourServicePublisherBackend { request, onEvent in
        let registration = SystemBonjourRegistration(request: request, onEvent: onEvent)
        try registration.start()
        return {
            registration.stop()
        }
    }
}

/// 将已有 HTTP listener 发布为固定 `xmnote.local`，并以 generation 阻止旧 C 回调污染新网络状态。
@MainActor
final class BonjourServicePublisher {
    nonisolated private static let hostname = "xmnote.local."
    nonisolated private static let browserHostname = "xmnote.local"
    nonisolated private static let serviceName = "XMNote"
    nonisolated private static let serviceType = "_http._tcp."
    nonisolated private static let domain = "local."

    private let backend: BonjourServicePublisherBackend
    private var cancelRegistration: BonjourServicePublisherBackend.Cancellation?
    private var onEvent: (@MainActor @Sendable (BonjourServicePublisherEvent) -> Void)?
    private var generation = 0

    /// 注入 DNS-SD 后端；生产默认使用系统 mDNSResponder，单元测试可替换为无网络副作用的闭包。
    init(backend: BonjourServicePublisherBackend = .system) {
        self.backend = backend
    }

    /// 为当前真实局域网端点发布固定域名；模拟器回环和无有效接口时保持 IP-only 状态。
    func start(
        port: Int,
        endpoints: [LocalNetworkEndpoint],
        onEvent: @escaping @MainActor @Sendable (BonjourServicePublisherEvent) -> Void
    ) {
        stop()
        guard let request = Self.makeRequest(port: port, endpoints: endpoints) else { return }

        self.onEvent = onEvent
        let currentGeneration = generation
        do {
            cancelRegistration = try backend.start(request) { [weak self] backendEvent in
                Task { @MainActor [weak self] in
                    guard let self, generation == currentGeneration else { return }
                    handle(backendEvent, publishedURL: request.url)
                }
            }
        } catch let error as BonjourServiceRegistrationError {
            handleFailure(code: error.code)
        } catch {
            onEvent(.unavailable(
                message: "xmnote.local 暂时无法发布，当前已改用局域网 IP 地址。"
            ))
        }
    }

    /// 撤销当前域名与服务公告；generation 先失效，迟到回调即使已排队也不能写回当前会话。
    func stop() {
        generation &+= 1
        let cancellation = cancelRegistration
        cancelRegistration = nil
        onEvent = nil
        cancellation?()
    }

    /// 把展示端点转换为系统 DNS-SD 使用的网络字节序记录；无真实接口时不构造发布请求。
    nonisolated static func makeRequest(
        port: Int,
        endpoints: [LocalNetworkEndpoint],
        interfaceIndexResolver: (String) -> UInt32 = { if_nametoindex($0) }
    ) -> BonjourServiceRegistrationRequest? {
        guard (1...Int(UInt16.max)).contains(port) else { return nil }

        let records = endpoints.compactMap { endpoint -> BonjourIPv4Record? in
            guard endpoint.interfaceName != "simulator-loopback" else { return nil }
            let interfaceIndex = interfaceIndexResolver(endpoint.interfaceName)
            guard interfaceIndex != 0 else { return nil }

            var address = in_addr()
            guard inet_pton(AF_INET, endpoint.host, &address) == 1 else { return nil }
            let addressData = withUnsafeBytes(of: &address.s_addr) { Data($0) }
            return BonjourIPv4Record(
                interfaceIndex: interfaceIndex,
                addressData: addressData
            )
        }
        guard !records.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = browserHostname
        components.port = port
        components.path = "/"
        guard let url = components.url else { return nil }

        return BonjourServiceRegistrationRequest(
            hostname: hostname,
            serviceName: serviceName,
            serviceType: serviceType,
            domain: domain,
            networkPort: UInt16(port).bigEndian,
            url: url,
            addressRecords: records
        )
    }

    /// 将底层结果压缩为 UI 需要的三态；服务发现的普通失败不否定已经成功的固定域名。
    private func handle(
        _ backendEvent: BonjourServiceBackendEvent,
        publishedURL: URL
    ) {
        switch backendEvent {
        case .addressesPublished:
            onEvent?(.published(url: publishedURL))
        case .addressRegistrationFailed(let code):
            handleFailure(code: code)
        case .serviceRegistrationFailed(let code):
            if code == Int32(kDNSServiceErr_PolicyDenied) {
                handleFailure(code: code)
            }
        }
    }

    /// 保留精确名称冲突与权限拒绝语义，其他系统错误统一回退 IP 并附带错误码用于排障。
    private func handleFailure(code: Int32) {
        if code == Int32(kDNSServiceErr_PolicyDenied) {
            onEvent?(.policyDenied(
                message: "本地网络权限被拒绝，请在“设置”中允许 XMNote 访问本地网络"
            ))
        } else if code == Int32(kDNSServiceErr_NameConflict) {
            onEvent?(.unavailable(
                message: "xmnote.local 已被局域网中的其他设备占用，当前已改用局域网 IP 地址。"
            ))
        } else {
            onEvent?(.unavailable(
                message: "xmnote.local 暂时无法发布（错误码 \(code)），当前已改用局域网 IP 地址。"
            ))
        }
    }
}

/// 携带同步 DNS-SD 启动失败的原始错误码，交由 MainActor 统一映射用户语义。
nonisolated private struct BonjourServiceRegistrationError: Error {
    let code: Int32
}

/// 仅在专用串行队列读写 C 引用，确保设置 dispatch queue 后的释放与回调位于同一队列。
nonisolated private final class SystemBonjourRegistration: @unchecked Sendable {
    private let request: BonjourServiceRegistrationRequest
    private let onEvent: @Sendable (BonjourServiceBackendEvent) -> Void
    private let queue = DispatchQueue(label: "com.xmnote.bonjour-publisher")
    private var connectionRef: DNSServiceRef?
    private var serviceRef: DNSServiceRef?
    private var recordRefs: [DNSRecordRef] = []
    private var successfulAddressCount = 0
    private var hasPublishedAddresses = false
    private var isStopped = false

    /// 保存不可变请求与跨队列事件出口；所有可变引用只允许在 `queue` 上访问。
    init(
        request: BonjourServiceRegistrationRequest,
        onEvent: @escaping @Sendable (BonjourServiceBackendEvent) -> Void
    ) {
        self.request = request
        self.onEvent = onEvent
    }

    /// 在专用队列同步创建连接和记录，避免首个异步回调与剩余注册步骤并发访问同一引用。
    func start() throws {
        try queue.sync {
            try startOnQueue()
        }
    }

    /// 异步切回原 dispatch queue 撤销公告；排队块持有 self，保证 C context 在释放完成前有效。
    func stop() {
        queue.async { [self] in
            cleanupOnQueue()
        }
    }

    /// 创建共享记录连接、逐接口 A 记录和辅助 HTTP 服务；任一同步错误都执行确定性清理。
    private func startOnQueue() throws {
        var newConnection: DNSServiceRef?
        var errorCode = DNSServiceCreateConnection(&newConnection)
        guard errorCode == kDNSServiceErr_NoError, let newConnection else {
            throw BonjourServiceRegistrationError(code: errorCode)
        }
        connectionRef = newConnection

        errorCode = DNSServiceSetDispatchQueue(newConnection, queue)
        guard errorCode == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(newConnection)
            connectionRef = nil
            throw BonjourServiceRegistrationError(code: errorCode)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        for record in request.addressRecords {
            var recordRef: DNSRecordRef?
            errorCode = request.hostname.withCString { hostname in
                record.addressData.withUnsafeBytes { addressBytes in
                    DNSServiceRegisterRecord(
                        newConnection,
                        &recordRef,
                        kDNSServiceFlagsUnique,
                        record.interfaceIndex,
                        hostname,
                        UInt16(kDNSServiceType_A),
                        UInt16(kDNSServiceClass_IN),
                        UInt16(addressBytes.count),
                        addressBytes.baseAddress,
                        0,
                        bonjourAddressRecordReply,
                        context
                    )
                }
            }
            guard errorCode == kDNSServiceErr_NoError, let recordRef else {
                cleanupOnQueue()
                throw BonjourServiceRegistrationError(code: errorCode)
            }
            recordRefs.append(recordRef)
        }

        var newServiceRef: DNSServiceRef?
        errorCode = request.serviceName.withCString { serviceName in
            request.serviceType.withCString { serviceType in
                request.domain.withCString { domain in
                    request.hostname.withCString { hostname in
                        DNSServiceRegister(
                            &newServiceRef,
                            0,
                            0,
                            serviceName,
                            serviceType,
                            domain,
                            hostname,
                            request.networkPort,
                            0,
                            nil,
                            bonjourServiceRegistrationReply,
                            context
                        )
                    }
                }
            }
        }
        guard errorCode == kDNSServiceErr_NoError, let newServiceRef else {
            onEvent(.serviceRegistrationFailed(code: errorCode))
            return
        }
        serviceRef = newServiceRef

        errorCode = DNSServiceSetDispatchQueue(newServiceRef, queue)
        guard errorCode == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(newServiceRef)
            serviceRef = nil
            onEvent(.serviceRegistrationFailed(code: errorCode))
            return
        }
    }

    /// 汇总所有接口的 A 记录确认；固定域名必须在当前全部真实局域网接口上无冲突才对外展示。
    fileprivate func handleAddressReply(errorCode: Int32) {
        guard !isStopped else { return }
        guard errorCode == kDNSServiceErr_NoError else {
            onEvent(.addressRegistrationFailed(code: errorCode))
            queue.async { [self] in
                cleanupOnQueue()
            }
            return
        }

        successfulAddressCount += 1
        guard !hasPublishedAddresses,
              successfulAddressCount == request.addressRecords.count else {
            return
        }
        hasPublishedAddresses = true
        onEvent(.addressesPublished)
    }

    /// HTTP 服务普通失败只关闭辅助公告；权限拒绝仍上抛，避免把系统授权问题伪装成可用状态。
    fileprivate func handleServiceReply(errorCode: Int32) {
        guard !isStopped, errorCode != kDNSServiceErr_NoError else { return }
        onEvent(.serviceRegistrationFailed(code: errorCode))
        queue.async { [self] in
            if errorCode == Int32(kDNSServiceErr_PolicyDenied) {
                cleanupOnQueue()
            } else {
                deallocateServiceOnQueue()
            }
        }
    }

    /// 在 DNS-SD 指定队列上先撤销服务、再关闭共享连接；关闭连接会同时失效全部 record ref。
    private func cleanupOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        deallocateServiceOnQueue()
        if let connectionRef {
            DNSServiceRefDeallocate(connectionRef)
            self.connectionRef = nil
        }
        recordRefs.removeAll()
    }

    /// 单独撤销辅助服务，保留已经成功注册的固定 A 记录。
    private func deallocateServiceOnQueue() {
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
        }
    }
}

/// 将系统 A 记录回调转回所属串行 session；context 由 session 的取消闭包覆盖完整生命周期。
nonisolated private let bonjourAddressRecordReply: DNSServiceRegisterRecordReply = {
    _, _, _, errorCode, context in
    guard let context else { return }
    let registration = Unmanaged<SystemBonjourRegistration>
        .fromOpaque(context)
        .takeUnretainedValue()
    registration.handleAddressReply(errorCode: errorCode)
}

/// 将系统服务公告回调转回所属串行 session；服务名自动冲突改名不影响固定主机名。
nonisolated private let bonjourServiceRegistrationReply: DNSServiceRegisterReply = {
    _, _, errorCode, _, _, _, context in
    guard let context else { return }
    let registration = Unmanaged<SystemBonjourRegistration>
        .fromOpaque(context)
        .takeUnretainedValue()
    registration.handleServiceReply(errorCode: errorCode)
}
