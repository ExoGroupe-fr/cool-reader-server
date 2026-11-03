import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// This machine on the network: its LAN addresses and its default gateway (the home router, usually), read from
/// the system without spawning processes, and a UDP socket for the short exchanges with that router.
nonisolated enum NetworkInterfaces {
    /// Interfaces of containers, virtual machines and VPNs: not where a phone on the LAN finds this machine.
    static let virtualPrefixes = ["lo", "docker", "br-", "veth", "virbr", "vmnet", "vmenet", "vboxnet", "utun", "tun", "tap",
                                  "bridge", "awdl", "llw", "gif", "stf", "anpi", "ipsec", "zt", "tailscale", "wg", "cni",
                                  "flannel", "cali", "kube", "podman", "lxc", "lxd", "shim-"]

    static func isVirtual(_ interface: String) -> Bool {
        virtualPrefixes.contains { interface.hasPrefix($0) }
    }

    /// This machine's LAN IPv4 addresses, the one that reaches the router first. Loopback, link-local and virtual
    /// interfaces are skipped. IPv6 is left out: macOS doesn't tell its temporary addresses, which change every
    /// day, from the stable one without private calls.
    static func localAddresses() -> [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = UInt32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let name = entry.ifa_name, !isVirtual(String(cString: name)) else { continue }
            let text = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
            guard !text.hasPrefix("169.254."), !found.contains(text) else { continue }
            found.append(text)
        }
        if let gateway = defaultGateway(), let preferred = localAddress(toward: gateway), let index = found.firstIndex(of: preferred) {
            found.insert(found.remove(at: index), at: 0)
        }
        return found
    }

    /// The IPv4 default gateway: the routing table on macOS (sysctl), /proc/net/route on Linux.
    static func defaultGateway() -> String? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        // The table can grow between the call that sizes it and the one that reads it.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            length += length / 4
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                return gateway(fromRoutingMessages: Array(buffer.prefix(length)))
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
        #else
        // /proc files report a size of 0: read to the end rather than by size.
        guard let handle = FileHandle(forReadingAtPath: "/proc/net/route"), let data = try? handle.readToEnd() else { return nil }
        try? handle.close()
        return gateway(fromRouteTable: String(decoding: data, as: UTF8.self))
        #endif
    }

    /// The default route in Linux's /proc/net/route: destination and mask 0, flags up and gateway, lowest metric.
    /// Addresses are the kernel's 32-bit values in hexadecimal, in the machine's byte order.
    static func gateway(fromRouteTable table: String) -> String? {
        var best: (metric: Int, address: String)?
        for line in table.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 8, !isVirtual(String(fields[0])), UInt32(fields[1], radix: 16) == 0, UInt32(fields[7], radix: 16) == 0,
                  let gateway = UInt32(fields[2], radix: 16), gateway != 0,
                  let flags = UInt32(fields[3], radix: 16), flags & 0x3 == 0x3 else { continue }
            let metric = Int(fields[6]) ?? 0
            let address = withUnsafeBytes(of: gateway) { $0.map(String.init).joined(separator: ".") }
            if best == nil || metric < best!.metric { best = (metric, address) }
        }
        return best?.address
    }

    #if canImport(Darwin)
    /// The default route among routing messages (sysctl NET_RT_FLAGS): a route through a gateway to 0.0.0.0. The
    /// primary interface's comes first; routes scoped to another interface and routes through virtual ones are
    /// used only when there is nothing else.
    static func gateway(fromRoutingMessages bytes: [UInt8]) -> String? {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var offset = 0
        var fallback: String?
        while offset + headerSize <= bytes.count {
            let header = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= bytes.count else { break }
            let addresses = ipv4Sockaddrs(bytes[(offset + headerSize)..<(offset + length)], present: header.rtm_addrs)
            offset += length
            guard header.rtm_flags & RTF_GATEWAY != 0, addresses[Int(RTAX_DST)] == [0, 0, 0, 0],
                  let gateway = addresses[Int(RTAX_GATEWAY)], gateway != [0, 0, 0, 0] else { continue }
            let address = gateway.map(String.init).joined(separator: ".")
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let isVirtual = if_indextoname(UInt32(header.rtm_index), &name) != nil
                && isVirtual(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            if header.rtm_flags & RTF_IFSCOPE == 0, !isVirtual { return address }
            fallback = fallback ?? address
        }
        return fallback
    }

    /// The IPv4 addresses of a routing message's sockaddrs, by RTAX index. An empty sockaddr is 0.0.0.0 (the
    /// default route's destination); each is padded to 4 bytes.
    private static func ipv4Sockaddrs(_ bytes: ArraySlice<UInt8>, present: Int32) -> [Int: [UInt8]] {
        var found: [Int: [UInt8]] = [:]
        var cursor = bytes.startIndex
        for index in 0..<Int(RTAX_MAX) where present & (1 << index) != 0 {
            guard cursor < bytes.endIndex else { break }
            let length = Int(bytes[cursor])
            if length == 0 {
                found[index] = [0, 0, 0, 0]
            } else if length >= 8, cursor + 8 <= bytes.endIndex, bytes[cursor + 1] == UInt8(AF_INET) {
                found[index] = Array(bytes[(cursor + 4)..<(cursor + 8)])
            }
            cursor += length == 0 ? 4 : (length + 3) & ~3
        }
        return found
    }
    #endif

    /// The address this machine uses to reach `gateway`, the one the router must forward to. Connecting a UDP
    /// socket only asks the routing table: nothing is sent.
    static func localAddress(toward gateway: String) -> String? {
        UDPSocket(connectedTo: gateway, port: 9)?.localAddress
    }

    enum AddressKind: Equatable, Sendable {
        /// Reachable from the internet.
        case `public`
        /// 10/8, 172.16/12, 192.168/16: the router is behind another router (double NAT).
        case `private`
        /// The operator's NAT, shared with its other customers: 100.64/10 (CGNAT) and 192.0.0/24 (DS-Lite).
        case shared
        /// 0.0.0.0, loopback, link-local, multicast and reserved: no address yet, or nothing to go by.
        case special
    }

    /// What a router's WAN address says about reaching this home from outside.
    static func kind(of address: String) -> AddressKind? {
        guard let bytes = ipv4Bytes(address) else { return nil }
        switch (bytes[0], bytes[1], bytes[2]) {
        case (10, _, _), (172, 16...31, _), (192, 168, _): return .private
        case (100, 64...127, _), (192, 0, 0): return .shared
        case (0, _, _), (127, _, _), (169, 254, _), (224...255, _, _): return .special
        default: return .public
        }
    }

    /// "192.0.2.1" as [192, 0, 2, 1]; nil for anything else (names, IPv6, "1.2.3", "+1.2.3.4").
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    static func ipv4String(_ address: in_addr) -> String {
        withUnsafeBytes(of: address) { $0.map(String.init).joined(separator: ".") }
    }

    private static let queue = DispatchQueue(label: "CoolReaderServer.router", attributes: .concurrent)

    /// Runs socket work that blocks (waits with a timeout) on a queue of its own: Swift concurrency's few threads
    /// must never wait on a router.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// A UDP socket for the short exchanges with the router (NAT-PMP, SSDP). Its calls block: use it in `blocking`.
    final class UDPSocket {
        enum Received {
            case datagram([UInt8], from: String)
            case timedOut
            /// The destination said nothing listens there (ICMP port unreachable, on a connected socket).
            case refused
            case failed
        }

        private let descriptor: Int32

        /// A socket bound to any port; connected to `host` when one is given, which keeps out other senders and
        /// reports a closed port as `refused`.
        init?(connectedTo host: String? = nil, port: Int = 0) {
            #if canImport(Darwin)
            descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            #else
            descriptor = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            #endif
            guard descriptor >= 0 else { return nil }
            if let host {
                guard var address = Self.socketAddress(host, port: port) else { return nil }
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                guard connected else { return nil }
            }
        }

        deinit {
            if descriptor >= 0 { close(descriptor) }
        }

        /// The local address the socket is bound to, once connected.
        var localAddress: String? {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) == 0 }
            }
            guard found else { return nil }
            let text = NetworkInterfaces.ipv4String(address.sin_addr)
            return text == "0.0.0.0" ? nil : text
        }

        /// Multicast goes out on the interface with this address, two hops at most (SSDP's TTL).
        func setMulticastInterface(_ local: String) {
            guard let bytes = NetworkInterfaces.ipv4Bytes(local) else { return }
            var address = in_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size))
            var hops: UInt8 = 2
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &hops, socklen_t(MemoryLayout<UInt8>.size))
        }

        /// Sends to the connected host, or to `host`.
        func send(_ bytes: [UInt8], to host: String? = nil, port: Int = 0) -> Bool {
            if let host {
                guard var address = Self.socketAddress(host, port: port) else { return false }
                return withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == bytes.count
                    }
                }
            }
            return sendto(descriptor, bytes, bytes.count, 0, nil, 0) == bytes.count
        }

        /// The next datagram within `timeout` seconds.
        func receive(timeout: TimeInterval) -> Received {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let milliseconds = Int32(max(0, (deadline.timeIntervalSinceNow * 1000).rounded(.up)))
                var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&entry, 1, milliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .failed
                }
                if ready == 0 { return .timedOut }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let capacity = buffer.count
                var source = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, capacity, 0, $0, &length) }
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return errno == ECONNREFUSED ? .refused : .failed
                }
                return .datagram(Array(buffer.prefix(count)), from: NetworkInterfaces.ipv4String(source.sin_addr))
            }
        }

        static func socketAddress(_ host: String, port: Int) -> sockaddr_in? {
            guard let bytes = NetworkInterfaces.ipv4Bytes(host), (0...65535).contains(port) else { return nil }
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port)).bigEndian
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
            return address
        }
    }
}
