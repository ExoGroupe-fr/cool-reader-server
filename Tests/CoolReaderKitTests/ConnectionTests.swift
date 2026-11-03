import Foundation
import NIOHTTP1
import Testing
@testable import CoolReaderKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ConnectionTests {
    @Test func tellsHomeAddressesFromTheInternet() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.10", "169.254.3.4", "100.101.102.103",
                        "::1", "fe80::1c2:3", "fd7a:115c:a1e0::1", "::ffff:192.168.1.10"] {
            #expect(Request.isLocal(address), "\(address)")
        }
        for address in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "203.0.113.5", "2a01:e0a:1::1", "::ffff:8.8.8.8", "garbage"] {
            #expect(!Request.isLocal(address), "\(address)")
        }
    }

    /// From the internet, plain HTTP pages move to HTTPS and the rest is refused; TLS or the home network pass.
    @Test func keepsPlainHTTPAtHome() async {
        var router = Router()
        router.add(.GET, "/api/v1/server") { _ in .json(["ok": true]) }
        router.add(.POST, "/api/v1/login") { _ in .json(["ok": true]) }
        func request(_ method: HTTPMethod, from address: String, secure: Bool = false) -> Request {
            var request = ServerTests.request("/api/v1/server", method: method)
            if method == .POST { request.path = "/api/v1/login" }
            request.uri = request.path
            request.headers.add(name: "Host", value: "example.org:7272")
            request.remoteAddress = address
            request.isSecure = secure
            return request
        }
        let moved = await ServerInstance.handle(request(.GET, from: "203.0.113.5"), routes: router)
        #expect(moved.status == .temporaryRedirect)
        #expect(moved.headers.first(name: "Location") == "https://example.org:7272/api/v1/server")
        #expect(await ServerInstance.handle(request(.POST, from: "203.0.113.5"), routes: router).status == .forbidden)
        #expect(await ServerInstance.handle(request(.POST, from: "203.0.113.5", secure: true), routes: router).status == .ok)
        #expect(await ServerInstance.handle(request(.POST, from: "192.168.1.20"), routes: router).status == .ok)
    }

    /// An invitation signs in one device, once; its link carries the addresses and the certificate's fingerprint.
    @Test func invitationsSignInOneDeviceOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try Store(path: folder.appendingPathComponent("library.sqlite").path)
        let context = try ServerContext(config: ServerConfig(configDirectory: folder), store: store)
        let lea = try #require(store.user(id: try store.createUser(name: "Lea", passwordHash: "", isAdmin: false, allLibraries: true, libraryIDs: [])))

        let addresses = context.addresses(requestHost: "nas.local", local: ["192.168.1.10"], public: ["example.duckdns.org:7272"])
        #expect(addresses == ["nas.local:7272", "192.168.1.10:7272", "example.duckdns.org:7272"])
        let invitation = try context.invite(lea, lifetime: 3600, addresses: addresses)
        let items = try #require(URLComponents(string: invitation.link)?.queryItems)
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(invitation.link.hasPrefix("coolreader://connect?"))
        #expect(item("a") == addresses.joined(separator: ","))
        #expect(item("fp") == context.certificate.fingerprint)
        #expect(item("s") == context.serverID)
        #expect(item("i") == invitation.secret)
        #expect(store.openInvitations().count == 1)

        let redeemed = try #require(try await context.redeem(invitation: invitation.secret, deviceName: "iPad", from: "192.168.1.20"))
        #expect(redeemed.user.name == "Lea")
        #expect(await context.caller(ServerTests.request("/", token: redeemed.token))?.user.id == lea.id)
        #expect(try await context.redeem(invitation: invitation.secret, deviceName: "iPhone", from: "192.168.1.20") == nil)
        #expect(store.openInvitations().isEmpty)

        let expired = try context.invite(lea, lifetime: -1, addresses: addresses)
        #expect(try await context.redeem(invitation: expired.secret, deviceName: "iPhone", from: "192.168.1.20") == nil)
        // A password-less member can't sign in with one.
        await #expect(throws: HTTPError.self) { try await context.signIn(name: "Lea", password: "", from: "192.168.1.20") }
    }

    /// Progress read offline arrives late: the newer reading wins, whatever the order.
    @Test func keepsTheNewerProgress() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try Store(path: folder.appendingPathComponent("library.sqlite").path)
        let user = try store.createUser(name: "Admin", passwordHash: "", isAdmin: true, allLibraries: true, libraryIDs: [])
        let library = try store.addLibrary(name: "Romans", path: folder.path)
        try store.database.execute("""
            INSERT INTO series (id, library_id, key, folder_title, kind, added_at, updated_at) VALUES (1, ?, 'k', 'Dune', 'book', 0, 0)
            """, [library])
        try store.database.execute("""
            INSERT INTO books (id, series_id, library_id, path, file_name, format, file_size, plain_name, position, added_at)
            VALUES (1, 1, ?, 'Dune.epub', 'Dune.epub', 'epub', 1, 'Dune', 0, 0)
            """, [library])
        let now = Date()
        try store.setProgress(userID: user, ProgressRecord(bookID: 1, page: 40, finished: false, position: "c4", fraction: 0.4, updatedAt: now))
        try store.setProgress(userID: user, ProgressRecord(bookID: 1, page: 10, finished: false, position: "c1", fraction: 0.1,
                                                         updatedAt: now.addingTimeInterval(-3600)))
        #expect(store.progress(userID: user, bookID: 1)?.position == "c4")
        try store.setProgress(userID: user, ProgressRecord(bookID: 1, page: 50, finished: true, position: nil, fraction: 1,
                                                         updatedAt: now.addingTimeInterval(60)))
        let progress = try #require(store.progress(userID: user, bookID: 1))
        #expect(progress.page == 50 && progress.finished && progress.fraction == 1)
    }

    #if canImport(Security)
    /// One port answers HTTP and HTTPS; a client that pins the certificate's fingerprint, as Cool Reader does, gets
    /// in, and one expecting another certificate doesn't.
    @Test func servesHTTPSOnTheSamePortToAClientThatPinsTheCertificate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificate = try ServerCertificate.loadOrCreate(in: folder)
        #expect(try ServerCertificate.loadOrCreate(in: folder).fingerprint == certificate.fingerprint)

        let (ports, listener) = AsyncStream<Int>.makeStream()
        let server = Task {
            try await HTTPServer.run(host: "127.0.0.1", port: 0, tls: certificate.sslContext, handler: { request in
                .json(["secure": request.isSecure])
            }, onListening: { listener.yield($0) })
        }
        defer { server.cancel() }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())

        let plain = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect(String(decoding: plain.0, as: UTF8.self) == #"{"secure":false}"#)

        let pinned = URLSession(configuration: .ephemeral, delegate: Pinning(fingerprint: certificate.fingerprint), delegateQueue: nil)
        let secure = try await pinned.data(from: URL(string: "https://127.0.0.1:\(port)/")!)
        #expect(String(decoding: secure.0, as: UTF8.self) == #"{"secure":true}"#)

        let wrong = URLSession(configuration: .ephemeral, delegate: Pinning(fingerprint: String(repeating: "0", count: 64)), delegateQueue: nil)
        await #expect(throws: (any Error).self) { _ = try await wrong.data(from: URL(string: "https://127.0.0.1:\(port)/")!) }
    }

    final class Pinning: NSObject, URLSessionDelegate, Sendable {
        let fingerprint: String

        init(fingerprint: String) { self.fingerprint = fingerprint }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  ServerCertificate.fingerprint(of: Array(SecCertificateCopyData(leaf) as Data)) == fingerprint else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
    #endif
}
