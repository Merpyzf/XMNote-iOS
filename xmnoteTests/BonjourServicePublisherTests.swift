/**
 * [INPUT]: 依赖可注入 BonjourServicePublisherBackend、固定域名请求编码与 DesktopWebAccessAddresses
 * [OUTPUT]: 验证固定 A 记录、端口字节序、发布确认、错误回退、权限拒绝、取消与过期回调隔离
 * [POS]: iOS App 无真实组播副作用的固定局域网域名单元测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
import dnssd
@testable import xmnote

@MainActor
struct BonjourServicePublisherTests {
    @Test
    func requestEncodesFixedHostnameIPv4InterfaceAndNetworkPort() throws {
        let endpoint = try #require(makeEndpoint(
            interfaceName: "en-test",
            host: "192.168.50.27"
        ))
        var resolvedInterfaceNames: [String] = []

        let request = try #require(BonjourServicePublisher.makeRequest(
            port: 8090,
            endpoints: [endpoint],
            interfaceIndexResolver: { name in
                resolvedInterfaceNames.append(name)
                return 42
            }
        ))

        #expect(resolvedInterfaceNames == ["en-test"])
        #expect(request.hostname == "xmnote.local.")
        #expect(request.serviceName == "XMNote")
        #expect(request.serviceType == "_http._tcp.")
        #expect(request.domain == "local.")
        #expect(request.networkPort == UInt16(8090).bigEndian)
        #expect(request.url.absoluteString == "http://xmnote.local:8090/")
        #expect(request.addressRecords == [
            BonjourIPv4Record(
                interfaceIndex: 42,
                addressData: Data([192, 168, 50, 27])
            )
        ])
    }

    @Test
    func publisherWaitsForAddressConfirmationBeforeExposingDomain() async throws {
        let backendProbe = BonjourBackendProbe()
        let eventProbe = BonjourEventProbe()
        let publisher = BonjourServicePublisher(backend: backendProbe.backend)
        let endpoint = try #require(makeEndpoint(interfaceName: "lo0", host: "10.0.0.8"))

        publisher.start(port: 8090, endpoints: [endpoint]) { event in
            eventProbe.events.append(event)
        }

        #expect(eventProbe.events.isEmpty)
        #expect(backendProbe.requests.count == 1)

        backendProbe.send(.addressesPublished, registration: 0)
        await settleCallbacks()

        #expect(eventProbe.events == [
            .published(url: URL(string: "http://xmnote.local:8090/")!)
        ])
    }

    @Test
    func errorsPreserveExactFallbackAndPermissionSemantics() async throws {
        let backendProbe = BonjourBackendProbe()
        let eventProbe = BonjourEventProbe()
        let publisher = BonjourServicePublisher(backend: backendProbe.backend)
        let endpoint = try #require(makeEndpoint(interfaceName: "lo0", host: "10.0.0.9"))

        publisher.start(port: 8090, endpoints: [endpoint]) { event in
            eventProbe.events.append(event)
        }
        backendProbe.send(
            .addressRegistrationFailed(code: Int32(kDNSServiceErr_NameConflict)),
            registration: 0
        )
        await settleCallbacks()
        #expect(eventProbe.events.last == .unavailable(
            message: "xmnote.local 已被局域网中的其他设备占用，当前已改用局域网 IP 地址"
        ))

        publisher.start(port: 8090, endpoints: [endpoint]) { event in
            eventProbe.events.append(event)
        }
        backendProbe.send(
            .addressRegistrationFailed(code: Int32(kDNSServiceErr_Unknown)),
            registration: 1
        )
        await settleCallbacks()
        #expect(eventProbe.events.last == .unavailable(
            message: "xmnote.local 暂时无法发布（错误码 \(Int32(kDNSServiceErr_Unknown))），当前已改用局域网 IP 地址"
        ))

        publisher.start(port: 8090, endpoints: [endpoint]) { event in
            eventProbe.events.append(event)
        }
        let countBeforeServiceFailure = eventProbe.events.count
        backendProbe.send(
            .serviceRegistrationFailed(code: Int32(kDNSServiceErr_NameConflict)),
            registration: 2
        )
        await settleCallbacks()
        #expect(eventProbe.events.count == countBeforeServiceFailure)

        backendProbe.send(
            .serviceRegistrationFailed(code: Int32(kDNSServiceErr_PolicyDenied)),
            registration: 2
        )
        await settleCallbacks()
        #expect(eventProbe.events.last == .policyDenied(
            message: "本地网络权限被拒绝，请在“设置”中允许 XMNote 访问本地网络"
        ))
    }

    @Test
    func replacementAndStopCancelOnceAndIgnoreStaleCallbacks() async throws {
        let backendProbe = BonjourBackendProbe()
        let eventProbe = BonjourEventProbe()
        let publisher = BonjourServicePublisher(backend: backendProbe.backend)
        let firstEndpoint = try #require(makeEndpoint(interfaceName: "lo0", host: "10.0.0.10"))
        let secondEndpoint = try #require(makeEndpoint(interfaceName: "lo0", host: "10.0.0.11"))

        publisher.start(port: 8090, endpoints: [firstEndpoint]) { event in
            eventProbe.events.append(event)
        }
        publisher.start(port: 8090, endpoints: [secondEndpoint]) { event in
            eventProbe.events.append(event)
        }

        #expect(backendProbe.cancellationCount == 1)
        backendProbe.send(.addressesPublished, registration: 0)
        await settleCallbacks()
        #expect(eventProbe.events.isEmpty)

        backendProbe.send(.addressesPublished, registration: 1)
        await settleCallbacks()
        #expect(eventProbe.events.count == 1)

        publisher.stop()
        publisher.stop()
        #expect(backendProbe.cancellationCount == 2)

        backendProbe.send(
            .addressRegistrationFailed(code: Int32(kDNSServiceErr_NameConflict)),
            registration: 1
        )
        await settleCallbacks()
        #expect(eventProbe.events.count == 1)
    }

    @Test
    func simulatorOnlyOrInvalidEndpointsDoNotStartBackend() throws {
        let backendProbe = BonjourBackendProbe()
        let publisher = BonjourServicePublisher(backend: backendProbe.backend)
        let simulatorEndpoint = try #require(makeEndpoint(
            interfaceName: "simulator-loopback",
            host: "127.0.0.1"
        ))
        let unresolvedEndpoint = try #require(makeEndpoint(
            interfaceName: "missing-interface",
            host: "192.168.1.2"
        ))

        publisher.start(port: 8090, endpoints: [simulatorEndpoint]) { _ in }
        publisher.start(port: 8090, endpoints: [unresolvedEndpoint]) { _ in }

        #expect(backendProbe.requests.isEmpty)
    }

    @Test
    func accessAddressesPreferDomainButRetainIPFallbackAndSimulatorIdentity() throws {
        let endpoint = try #require(makeEndpoint(interfaceName: "en0", host: "192.168.1.20"))
        let base = DesktopWebAccessAddresses(
            domainURL: nil,
            ipEndpoints: [endpoint],
            domainStatusMessage: nil
        )
        let domainURL = try #require(URL(string: "http://xmnote.local:8090/"))

        let published = base.applying(.published(url: domainURL))
        #expect(published.domainURL == domainURL)
        #expect(published.ipEndpoints == [endpoint])
        #expect(published.domainStatusMessage == nil)

        let fallback = published.applying(.unavailable(message: "域名冲突"))
        #expect(fallback.domainURL == nil)
        #expect(fallback.ipEndpoints == [endpoint])
        #expect(fallback.domainStatusMessage == "域名冲突")

        let simulatorEndpoint = try #require(makeEndpoint(
            interfaceName: "simulator-loopback",
            host: "127.0.0.1"
        ))
        #expect(DesktopWebAccessAddresses(
            domainURL: nil,
            ipEndpoints: [simulatorEndpoint],
            domainStatusMessage: nil
        ).isSimulatorOnly)
    }

    /// 创建与生产展示模型一致的端点，避免测试自行拼接 URL 造成编码差异。
    private func makeEndpoint(
        interfaceName: String,
        host: String
    ) -> LocalNetworkEndpoint? {
        guard let url = URL(string: "http://\(host):8090/") else { return nil }
        return LocalNetworkEndpoint(interfaceName: interfaceName, host: host, url: url)
    }

    /// 允许发布者把后台事件桥接回 MainActor，同时不引入真实时间等待。
    private func settleCallbacks() async {
        await Task.yield()
        await Task.yield()
    }
}

/// 记录后端请求、回调和取消次数，测试中不创建 DNSServiceRef 或组播套接字。
@MainActor
private final class BonjourBackendProbe {
    var requests: [BonjourServiceRegistrationRequest] = []
    var callbacks: [BonjourServicePublisherBackend.EventHandler] = []
    var cancellationCount = 0

    var backend: BonjourServicePublisherBackend {
        BonjourServicePublisherBackend { [weak self] request, onEvent in
            guard let self else {
                return {}
            }
            requests.append(request)
            callbacks.append(onEvent)
            return { [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    /// 主动驱动某次注册的系统事件；越界代表测试编排错误并由 `#expect` 报告。
    func send(_ event: BonjourServiceBackendEvent, registration: Int) {
        guard callbacks.indices.contains(registration) else {
            Issue.record("不存在第 \(registration) 次 Bonjour 注册")
            return
        }
        callbacks[registration](event)
    }
}

/// MainActor 事件收集器避免 `@Sendable` 回调直接捕获并修改局部数组。
@MainActor
private final class BonjourEventProbe {
    var events: [BonjourServicePublisherEvent] = []
}
