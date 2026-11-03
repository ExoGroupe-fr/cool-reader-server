import Foundation

/// NAT-PMP (RFC 6886), the port mapping protocol of Apple's routers and of many others: small UDP messages to the
/// gateway's port 5351, one for its WAN address, one per mapping.
nonisolated enum NATPMP {
    static let port = 5351
    /// An hour, renewed at half time: a mapping left behind by a crash closes by itself.
    static let lifetime = 3600

    enum Failure: Error, Equatable {
        /// No answer, or the gateway said nothing listens on its port: it doesn't speak NAT-PMP.
        case noAnswer
        /// It answered, but not to this version or opcode (a router that only speaks PCP).
        case unsupported
        /// It refused: not authorized (NAT-PMP turned off), no WAN connection, out of resources.
        case refused(code: Int)
        case malformed
    }

    struct ExternalAddress: Equatable, Sendable {
        var address: String
        /// Seconds since the router's NAT-PMP started: when it goes back, the router restarted and lost its mappings.
        var epoch: UInt32
    }

    struct Mapping: Equatable, Sendable {
        var internalPort: Int
        var externalPort: Int
        var lifetime: Int
        var epoch: UInt32
    }

    static let externalAddressRequest: [UInt8] = [0, 0]

    /// A TCP mapping (opcode 2). An external port of 0 with a lifetime of 0 removes the mapping.
    static func mappingRequest(internalPort: Int, externalPort: Int, lifetime: Int) -> [UInt8] {
        [0, 2, 0, 0] + bigEndian(UInt16(clamping: internalPort)) + bigEndian(UInt16(clamping: externalPort))
            + bigEndian(UInt32(clamping: lifetime))
    }

    static func parseExternalAddress(_ bytes: [UInt8]) throws -> ExternalAddress {
        try check(bytes, opcode: 128, length: 12)
        return ExternalAddress(address: bytes[8..<12].map(String.init).joined(separator: "."), epoch: uint32(bytes, at: 4))
    }

    static func parseMapping(_ bytes: [UInt8]) throws -> Mapping {
        try check(bytes, opcode: 130, length: 16)
        return Mapping(internalPort: Int(uint16(bytes, at: 8)), externalPort: Int(uint16(bytes, at: 10)),
                       lifetime: Int(uint32(bytes, at: 12)), epoch: uint32(bytes, at: 4))
    }

    /// What a result code means, for the admin page.
    static func describe(_ code: Int) -> String {
        switch code {
        case 2: "NAT-PMP is turned off or not allowed on the router, result 2"
        case 3: "the router has no internet connection yet, result 3"
        case 4: "the router can't map more ports, result 4"
        default: "NAT-PMP result \(code)"
        }
    }

    /// The router's WAN address.
    static func externalAddress(gateway: String, port: Int = NATPMP.port) async throws -> ExternalAddress {
        let answer = await NetworkInterfaces.blocking { exchange(externalAddressRequest, gateway: gateway, port: port) }
        return try parseExternalAddress(answer.get())
    }

    /// Maps `externalPort` (a wish: the router may give another) to this machine's `internalPort` for `lifetime`
    /// seconds; the router may grant less.
    static func map(internalPort: Int, externalPort: Int, lifetime: Int, gateway: String, port: Int = NATPMP.port) async throws -> Mapping {
        let request = mappingRequest(internalPort: internalPort, externalPort: externalPort, lifetime: lifetime)
        let answer = await NetworkInterfaces.blocking { exchange(request, gateway: gateway, port: port) }
        let mapping = try parseMapping(answer.get())
        guard mapping.internalPort == internalPort else { throw Failure.malformed }
        return mapping
    }

    /// Sends `request` and waits for the answer, sending again after 250 ms, then 500 ms, and so on (RFC 6886's
    /// backoff), for `budget` seconds at most: the admin page never waits long on a silent router. The socket is
    /// connected to the gateway, so only its answers come in, and a gateway without NAT-PMP fails at once.
    static func exchange(_ request: [UInt8], gateway: String, port: Int, budget: TimeInterval = 3) -> Result<[UInt8], Failure> {
        guard let socket = NetworkInterfaces.UDPSocket(connectedTo: gateway, port: port) else { return .failure(.noAnswer) }
        let deadline = Date().addingTimeInterval(budget)
        var wait: TimeInterval = 0.25
        while deadline.timeIntervalSinceNow > 0 {
            guard socket.send(request) else { return .failure(.noAnswer) }
            let resend = min(Date().addingTimeInterval(wait), deadline)
            while resend.timeIntervalSinceNow > 0 {
                switch socket.receive(timeout: resend.timeIntervalSinceNow) {
                case .datagram(let bytes, _):
                    // The answer to this opcode, or any answer in another version: ignore the rest.
                    if bytes.count >= 2, bytes[0] != 0 || bytes[1] == request[1] | 0x80 { return .success(bytes) }
                case .refused, .failed:
                    return .failure(.noAnswer)
                case .timedOut:
                    continue
                }
            }
            wait *= 2
        }
        return .failure(.noAnswer)
    }

    private static func check(_ bytes: [UInt8], opcode: UInt8, length: Int) throws {
        guard bytes.count >= 4 else { throw Failure.malformed }
        guard bytes[0] == 0 else { throw Failure.unsupported }
        guard bytes[1] == opcode else { throw Failure.malformed }
        switch Int(uint16(bytes, at: 2)) {
        case 0: guard bytes.count >= length else { throw Failure.malformed }
        case 1, 5: throw Failure.unsupported
        case let code: throw Failure.refused(code: code)
        }
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
