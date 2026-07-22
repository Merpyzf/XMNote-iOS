/**
 * [INPUT]: 依赖 Network.framework 的路径快照与 Darwin getifaddrs 网络接口枚举
 * [OUTPUT]: 对外提供去除回环、蜂窝和无效接口后的局域网 IPv4 地址与 HTTP URL 更新
 * [POS]: Services 的局域网端点唯一事实源，供桌面网页会话与 API 导入页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Darwin
import Foundation
import Network

/// 一个可展示、复制并编码为二维码的局域网 HTTP 访问端点。
nonisolated struct LocalNetworkEndpoint: Identifiable, Hashable, Sendable {
    let interfaceName: String
    let host: String
    let url: URL

    nonisolated var id: String {
        "\(interfaceName)|\(host)|\(url.port ?? 0)"
    }

    nonisolated var displayName: String {
        switch interfaceName {
        case "simulator-loopback":
            return "本机模拟器"
        default:
            return interfaceName
        }
    }
}

/// 监听系统网络路径，并将可用接口名与 getifaddrs 地址交叉校验后交给主线程 owner。
@MainActor
final class LocalNetworkEndpointProvider {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.xmnote.local-network-endpoints")
    private var isMonitoring = false

    /// 开始监听路径；枚举在专用串行队列完成，结果切回 MainActor，stop 后迟到回调由会话状态拦截。
    func start(
        port: Int,
        path: String = "/",
        onChange: @escaping @MainActor @Sendable ([LocalNetworkEndpoint]) -> Void
    ) {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.pathUpdateHandler = { networkPath in
            let endpoints = Self.makeEndpoints(from: networkPath, port: port, path: path)
            Task { @MainActor in
                onChange(endpoints)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// 停止监听并释放路径回调；同一 provider 实例停止后不再复用 NWPathMonitor。
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    /// 根据系统确认的可用接口枚举 IPv4 地址，明确排除 cellular、loopback 与未启用接口。
    nonisolated private static func makeEndpoints(
        from pathSnapshot: NWPath,
        port: Int,
        path requestPath: String
    ) -> [LocalNetworkEndpoint] {
        guard pathSnapshot.status == .satisfied else { return [] }
        let eligibleInterfaceNames = Set(
            pathSnapshot.availableInterfaces.compactMap { interface -> String? in
                switch interface.type {
                case .wifi, .wiredEthernet:
                    return interface.name
                case .cellular, .loopback, .other:
                    return nil
                @unknown default:
                    return nil
                }
            }
        )

        var interfaceAddresses: [(name: String, host: String)] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return simulatorFallback(port: port, path: requestPath)
        }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else {
                continue
            }
            let interfaceName = String(cString: interface.ifa_name)
            guard eligibleInterfaceNames.contains(interfaceName),
                  isUsableLANInterfaceName(interfaceName) else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let host = String(cString: hostBuffer)
            guard isUsableLANIPv4Address(host) else { continue }
            interfaceAddresses.append((interfaceName, host))
        }

        let endpoints = interfaceAddresses.compactMap { item -> LocalNetworkEndpoint? in
            guard let url = makeURL(host: item.host, port: port, path: requestPath) else { return nil }
            return LocalNetworkEndpoint(interfaceName: item.name, host: item.host, url: url)
        }
        let uniqueEndpoints = Dictionary(grouping: endpoints, by: \.id).compactMap(\.value.first)
        if uniqueEndpoints.isEmpty {
            return simulatorFallback(port: port, path: requestPath)
        }
        return uniqueEndpoints.sorted {
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName.localizedStandardCompare($1.interfaceName) == .orderedAscending
            }
            return $0.host.localizedStandardCompare($1.host) == .orderedAscending
        }
    }

    /// 使用 URLComponents 统一格式化端点，避免手工拼接路径与端口。
    nonisolated private static func makeURL(host: String, port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    /// 排除 VPN、隧道与点对点虚拟接口；真实接口名称仍由 NWPath 决定，不依赖固定的 en0。
    nonisolated private static func isUsableLANInterfaceName(_ name: String) -> Bool {
        let excludedPrefixes = ["utun", "tun", "tap", "ipsec", "ppp", "gif", "stf", "awdl", "llw"]
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    /// 排除未指定、回环、自分配、RFC 2544 测试、组播与广播地址，避免展示外部设备不可达的地址。
    nonisolated private static func isUsableLANIPv4Address(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let hostOrderAddress = UInt32(bigEndian: address.s_addr)
        let firstOctet = UInt8((hostOrderAddress >> 24) & 0xff)
        let secondOctet = UInt8((hostOrderAddress >> 16) & 0xff)

        guard firstOctet != 0,
              firstOctet != 127,
              !(firstOctet == 169 && secondOctet == 254),
              !(firstOctet == 198 && (secondOctet == 18 || secondOctet == 19)),
              firstOctet < 224,
              hostOrderAddress != UInt32.max else {
            return false
        }
        return true
    }

    /// 模拟器没有可发布局域网接口时仅提供回环验收地址；真机永不把 loopback 展示给外部设备。
    nonisolated private static func simulatorFallback(port: Int, path: String) -> [LocalNetworkEndpoint] {
        #if targetEnvironment(simulator)
        guard let url = makeURL(host: "127.0.0.1", port: port, path: path) else { return [] }
        return [LocalNetworkEndpoint(interfaceName: "simulator-loopback", host: "127.0.0.1", url: url)]
        #else
        return []
        #endif
    }
}
