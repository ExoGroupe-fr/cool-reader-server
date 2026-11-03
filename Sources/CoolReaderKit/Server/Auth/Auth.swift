import Crypto
import Foundation

/// Passwords hashed with PBKDF2-HMAC-SHA256: "pbkdf2-sha256$600000$salt$hash", salt and hash in base64.
nonisolated enum Passwords {
    static let iterations = 600_000

    static func hash(_ password: String, iterations: Int = iterations) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in salt.indices { salt[index] = generator.next() }
        let derived = pbkdf2(password: Array(password.utf8), salt: salt, iterations: iterations)
        return "pbkdf2-sha256$\(iterations)$\(Data(salt).base64EncodedString())$\(Data(derived).base64EncodedString())"
    }

    static func verify(_ password: String, hash: String) -> Bool {
        let parts = hash.split(separator: "$")
        guard parts.count == 4, parts[0] == "pbkdf2-sha256", let iterations = Int(parts[1]),
              let salt = Data(base64Encoded: String(parts[2])), let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let derived = pbkdf2(password: Array(password.utf8), salt: Array(salt), iterations: iterations)
        // Every byte compared, whatever differs first.
        guard derived.count == expected.count else { return false }
        return zip(derived, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// HMAC-SHA256 with the key's inner and outer states computed once: two SHA-256 blocks per round.
    static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        var key = password.count > 64 ? Array(SHA256.hash(data: password)) : password
        key += [UInt8](repeating: 0, count: 64 - key.count)
        var inner = SHA256()
        inner.update(data: key.map { $0 ^ 0x36 })
        var outer = SHA256()
        outer.update(data: key.map { $0 ^ 0x5C })
        func mac(_ message: [UInt8]) -> [UInt8] {
            var innerHash = inner
            innerHash.update(data: message)
            var outerHash = outer
            outerHash.update(data: Array(innerHash.finalize()))
            return Array(outerHash.finalize())
        }
        var block = mac(salt + [0, 0, 0, 1])
        var result = block
        for _ in 1..<max(1, iterations) {
            block = mac(block)
            for index in 0..<result.count { result[index] ^= block[index] }
        }
        return result
    }
}

/// Device tokens: 32 random bytes in URL-safe base64. Only their SHA-256 is stored.
nonisolated enum Tokens {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Six digits, for the first start and the pairing of a device.
    static func code() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}

/// Wrong passwords slow down: ten in a quarter of an hour from one address or for one name, then a pause.
actor LoginThrottle {
    private var failures: [String: [Date]] = [:]
    private let limit = 10
    private let window: TimeInterval = 15 * 60

    func isBlocked(_ keys: [String]) -> Bool {
        let since = Date().addingTimeInterval(-window)
        return keys.contains { key in (failures[key] ?? []).filter { $0 > since }.count >= limit }
    }

    func failed(_ keys: [String]) {
        let since = Date().addingTimeInterval(-window)
        for key in keys { failures[key] = (failures[key] ?? []).filter { $0 > since } + [Date()] }
    }

    func succeeded(_ keys: [String]) {
        for key in keys { failures[key] = nil }
    }
}

/// A device waiting to be paired: it shows a code, a signed-in account approves it, the device collects its token.
actor Pairings {
    struct Pending: Sendable {
        let id: String
        let code: String
        let deviceName: String
        let created = Date()
        var token: String?
        var userName: String?
    }

    private var pending: [String: Pending] = [:]
    private let lifetime: TimeInterval = 10 * 60

    func start(deviceName: String) -> Pending {
        expire()
        var code = Tokens.code()
        while pending.values.contains(where: { $0.code == code }) { code = Tokens.code() }
        let request = Pending(id: Tokens.make(), code: code, deviceName: String(deviceName.prefix(60)))
        pending[request.id] = request
        return request
    }

    /// The request, and its token once approved: handed out once, then the request is gone.
    func collect(id: String) -> Pending? {
        expire()
        guard let request = pending[id] else { return nil }
        if request.token != nil { pending[id] = nil }
        return request
    }

    /// Approves the device showing `code` for `user`; returns its name, or nil for an unknown code.
    func approve(code: String, user: UserRecord, store: Store) throws -> String? {
        expire()
        let digits = code.filter(\.isNumber)
        guard let id = pending.values.first(where: { $0.code == digits && $0.token == nil })?.id, var request = pending[id] else {
            return nil
        }
        let token = Tokens.make()
        _ = try store.addDevice(userID: user.id, name: request.deviceName, kind: "app", tokenHash: Tokens.hash(token))
        request.token = token
        request.userName = user.name
        pending[id] = request
        return request.deviceName
    }

    private func expire() {
        let since = Date().addingTimeInterval(-lifetime)
        pending = pending.filter { $0.value.created > since }
    }
}
