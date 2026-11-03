import Dispatch
import Foundation
import Testing
@testable import CoolReaderKit
#if canImport(dnssd)
import dnssd
#endif

/// DNS messages, the mDNS responder's answers (also over loopback, on a port the system picks) and, on the Mac, a
/// real registration with mDNSResponder.
struct BonjourTests {
    nonisolated static let serverID = "3f6c1d2e-8a4b-4c5d-9e6f-0a1b2c3d4e5f"
    nonisolated static let service = MDNSResponder.Service(instance: "Cool Reader Test", type: "_coolreader._tcp", host: "testhost", port: 7272,
                                                           txt: DNSMessage.txtStrings(["id": serverID, "v": "0.1.0", "api": "1"]))
    /// From TEST-NET-1 (RFC 5737): addresses that belong to no one.
    nonisolated static let address: [UInt8] = [192, 0, 2, 10]
    nonisolated static let otherAddress: [UInt8] = [192, 0, 2, 20]
    nonisolated static let typeName = DNSMessage.Name(dotted: "_coolreader._tcp.local")
    nonisolated static let instanceName = DNSMessage.Name(["Cool Reader Test", "_coolreader", "_tcp", "local"])
    nonisolated static let hostName = DNSMessage.Name(dotted: "testhost.local")
    nonisolated static let srv = DNSMessage.Record(name: instanceName, ttl: 120, data: .srv(priority: 0, weight: 0, port: 7272, target: hostName),
                                                   cacheFlush: true)
    nonisolated static let txt = DNSMessage.Record(name: instanceName, ttl: 4500, data: .txt(["api=1", "id=\(serverID)", "v=0.1.0"]),
                                                   cacheFlush: true)
    nonisolated static let a = DNSMessage.Record(name: hostName, ttl: 120, data: .a(address), cacheFlush: true)

    // MARK: - Messages

    /// A response with every record type the responder writes reads back the same, and each name is written once:
    /// the others point to it.
    @Test func encodesAndDecodesMessages() throws {
        let message = DNSMessage(id: 7, flags: DNSMessage.responseFlags,
                                 questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr, unicastResponse: true)],
                                 answers: [DNSMessage.Record(name: Self.typeName, ttl: 4500, data: .ptr(Self.instanceName))],
                                 additionals: [Self.srv, Self.txt, Self.a])
        let bytes = message.encoded()
        #expect(try DNSMessage(bytes: bytes) == message)
        #expect(Self.occurrences(of: "_coolreader", in: bytes) == 1)
        #expect(Self.occurrences(of: "Cool Reader Test", in: bytes) == 1)
        #expect(Self.occurrences(of: "testhost", in: bytes) == 1)
    }

    /// A packet written by hand, compressed the way other responders do it: a pointer into the first name, another
    /// into a PTR record's data, and an SRV target ending in a pointer.
    @Test func followsCompressionPointers() throws {
        var bytes: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 1]
        bytes += Self.label("_coolreader") + Self.label("_tcp") + Self.label("local") + [0]
        // A PTR to "Test" and a pointer to offset 12; its data starts at 46.
        bytes += [0, 12, 0, 1, 0, 0, 0x11, 0x94, 0, 7] + Self.label("Test") + [0xC0, 12]
        // An SRV named by a pointer to 46, its target "testhost" and a pointer to "local", at 29.
        bytes += [0xC0, 46, 0, 33, 0x80, 1, 0, 0, 0, 120, 0, 17, 0, 0, 0, 0, 0x1C, 0x68] + Self.label("testhost") + [0xC0, 29]
        let message = try DNSMessage(bytes: bytes)
        let test = DNSMessage.Name(["Test", "_coolreader", "_tcp", "local"])
        #expect(message.isResponse)
        #expect(message.answers == [DNSMessage.Record(name: Self.typeName, ttl: 4500, data: .ptr(test))])
        #expect(message.additionals == [DNSMessage.Record(name: test, ttl: 120, data: .srv(priority: 0, weight: 0, port: 7272, target: Self.hostName),
                                                          cacheFlush: true)])
    }

    /// Pointers to themselves, forward, or back to the start of their own name are refused, not followed forever;
    /// so are packets cut short.
    @Test func rejectsMalformedPackets() {
        let header: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(throws: DNSMessage.FormatError.self) { try DNSMessage(bytes: header + [0xC0, 12, 0, 12, 0, 1]) }
        #expect(throws: DNSMessage.FormatError.self) { try DNSMessage(bytes: header + [0xC0, 14, 0, 12, 0, 1, 0]) }
        #expect(throws: DNSMessage.FormatError.self) { try DNSMessage(bytes: header + Self.label("a") + [0xC0, 12, 0, 12, 0, 1]) }
        #expect(throws: DNSMessage.FormatError.self) { try DNSMessage(bytes: header + Self.label("local")) }
        #expect(throws: DNSMessage.FormatError.self) { try DNSMessage(bytes: Array(header.prefix(7))) }
    }

    // MARK: - Answers

    /// A browser asking for Cool Reader servers gets the PTR with the SRV, TXT and address it needs next as
    /// additional records, so it can connect without asking again. What it already knows isn't repeated.
    @Test func answersBrowsersWithTheRecordsTheyNeedNext() throws {
        let zone = MDNSResponder.Zone(service: Self.service)
        let query = DNSMessage(questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr)])
        let reply = try #require(zone.answer(query, addresses: [Self.address]))
        #expect(reply.answers == [DNSMessage.Record(name: Self.typeName, ttl: 4500, data: .ptr(Self.instanceName))])
        #expect(reply.additionals == [Self.srv, Self.txt, Self.a])

        var known = query
        known.answers = reply.answers
        #expect(zone.answer(known, addresses: [Self.address]) == nil)
        known.answers[0].ttl = 1000
        #expect(zone.answer(known, addresses: [Self.address])?.answers == reply.answers)

        // Resolving the instance: SRV and TXT, then the address with the SRV.
        let resolve = DNSMessage(questions: [DNSMessage.Question(name: Self.instanceName, type: DNSMessage.RecordType.any, unicastResponse: true)])
        let resolved = try #require(zone.answer(resolve, addresses: [Self.address]))
        #expect(resolved.answers == [Self.srv, Self.txt])
        #expect(resolved.additionals == [Self.a])
    }

    /// Queries for other services, or for names the server doesn't own, get no answer at all.
    @Test func staysSilentForOtherServices() {
        let zone = MDNSResponder.Zone(service: Self.service)
        for name in ["_http._tcp.local", "_coolreader._udp.local", "Other._coolreader._tcp.local", "otherhost.local"] {
            let query = DNSMessage(questions: [DNSMessage.Question(name: DNSMessage.Name(dotted: name), type: DNSMessage.RecordType.any)])
            #expect(zone.answer(query, addresses: [Self.address]) == nil)
        }
        let ipv6 = DNSMessage(questions: [DNSMessage.Question(name: Self.hostName, type: DNSMessage.RecordType.aaaa)])
        #expect(zone.answer(ipv6, addresses: [Self.address]) == nil)
    }

    /// DNS-SD's list of service types names Cool Reader's (RFC 6763 §9), whatever the case of the question.
    @Test func answersTheServiceTypesQuery() throws {
        let zone = MDNSResponder.Zone(service: Self.service)
        let query = DNSMessage(questions: [DNSMessage.Question(name: DNSMessage.Name(dotted: "_Services._DNS-SD._udp.local"),
                                                              type: DNSMessage.RecordType.ptr)])
        let reply = try #require(zone.answer(query, addresses: [Self.address]))
        #expect(reply.answers.map(\.data) == [DNSMessage.RecordData.ptr(Self.typeName)])
        #expect(reply.additionals.isEmpty)
    }

    /// Announcements carry every record, the cache-flush bit on those only this server owns; the goodbye is the same
    /// with a TTL of zero. Both fit in a packet.
    @Test func announcesAndSaysGoodbye() {
        let zone = MDNSResponder.Zone(service: Self.service)
        let announcement = zone.announcement(addresses: [Self.address])
        #expect(announcement.isResponse && announcement.id == 0 && announcement.questions.isEmpty)
        #expect(announcement.answers.count == 5)
        #expect(announcement.answers.filter(\.cacheFlush) == [Self.srv, Self.txt, Self.a])
        let goodbye = zone.goodbye(addresses: [Self.address])
        #expect(goodbye.answers.allSatisfy { $0.ttl == 0 && !$0.cacheFlush })
        #expect(zip(goodbye.answers, announcement.answers).allSatisfy { $0.isSame(as: $1) })
        #expect(announcement.encoded().count < MDNSResponder.packetLimit)

        // Hundreds of addresses: the additional records that don't fit are left out.
        let crowded = DNSMessage(flags: DNSMessage.responseFlags, answers: [Self.srv],
                                 additionals: (0..<200).map { DNSMessage.Record(name: Self.hostName, ttl: 120, data: .a([10, 0, 0, UInt8($0)])) })
        #expect(crowded.encoded(limit: MDNSResponder.packetLimit).count <= MDNSResponder.packetLimit)
    }

    // MARK: - Probing

    /// Another server answering a probe for the same name with other data: this one becomes "Cool Reader Test (2)",
    /// on "testhost-2" if the host name is taken too. Identical records are no conflict.
    @Test func renamesWhenAnotherServerAnswersItsProbe() {
        var zone = MDNSResponder.Zone(service: Self.service)
        let probe = zone.probe(addresses: [Self.address])
        #expect(!probe.isResponse)
        #expect(probe.questions.map(\.name) == [Self.instanceName, Self.hostName])
        #expect(probe.questions.allSatisfy { $0.type == DNSMessage.RecordType.any })
        #expect(probe.authorities.count == 3)
        #expect(zip(probe.authorities, [Self.srv, Self.txt, Self.a]).allSatisfy { $0.isSame(as: $1) && !$0.cacheFlush })

        let same = DNSMessage(flags: DNSMessage.responseFlags, answers: [Self.srv, Self.txt])
        #expect(zone.conflicts(in: same, addresses: [Self.address], localAddresses: []) == MDNSResponder.Zone.Conflicts())
        let gone = DNSMessage(flags: DNSMessage.responseFlags,
                              answers: [DNSMessage.Record(name: Self.instanceName, ttl: 0, data: .txt(["id=other"]))])
        #expect(zone.conflicts(in: gone, addresses: [Self.address], localAddresses: []) == MDNSResponder.Zone.Conflicts())

        let other = DNSMessage(flags: DNSMessage.responseFlags, answers: [
            DNSMessage.Record(name: Self.instanceName, ttl: 120,
                              data: .srv(priority: 0, weight: 0, port: 7373, target: DNSMessage.Name(dotted: "otherhost.local")), cacheFlush: true),
            DNSMessage.Record(name: Self.hostName, ttl: 120, data: .a(Self.otherAddress), cacheFlush: true),
        ])
        let conflicts = zone.conflicts(in: other, addresses: [Self.address], localAddresses: [])
        #expect(conflicts.instance && conflicts.host)
        zone.renameInstance()
        zone.renameHost()
        #expect(zone.instance == "Cool Reader Test (2)")
        #expect(zone.host == "testhost-2")
        #expect(zone.instanceName == DNSMessage.Name(["Cool Reader Test (2)", "_coolreader", "_tcp", "local"]))
        let renamedSRV = DNSMessage.RecordData.srv(priority: 0, weight: 0, port: 7272, target: DNSMessage.Name(dotted: "testhost-2.local"))
        #expect(zone.records(addresses: [Self.address]).contains { $0.data == renamedSRV })

        // The number fits in the label's 63 bytes.
        var long = MDNSResponder.Zone(service: MDNSResponder.Service(instance: String(repeating: "é", count: 40), type: "_coolreader._tcp",
                                                                     host: "testhost", port: 7272, txt: []))
        long.renameInstance()
        #expect(long.instance.utf8.count <= 63 && long.instance.hasSuffix("é (2)"))
    }

    /// The machine's own responder (Avahi) answering for its host name with one of its addresses isn't another
    /// machine: the name is kept, and the address records are left to that responder.
    @Test func leavesTheHostNameToThisMachinesResponder() {
        var zone = MDNSResponder.Zone(service: Self.service)
        let avahi = DNSMessage(flags: DNSMessage.responseFlags, answers: [DNSMessage.Record(name: Self.hostName, ttl: 120, data: .a(Self.otherAddress),
                                                                                           cacheFlush: true)])
        let conflicts = zone.conflicts(in: avahi, addresses: [Self.address], localAddresses: [Self.address, Self.otherAddress])
        #expect(conflicts == MDNSResponder.Zone.Conflicts(hostAnsweredLocally: true))
        zone.hostIsShared = true
        #expect(!zone.records(addresses: [Self.address]).contains { $0.type == DNSMessage.RecordType.a })
        #expect(zone.probe(addresses: [Self.address]).questions.map(\.name) == [Self.instanceName])
        let query = DNSMessage(questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr)])
        #expect(zone.answer(query, addresses: [Self.address])?.additionals == [Self.srv, Self.txt])
    }

    /// Host labels keep letters, digits and hyphens of the machine's name, up to its first dot.
    @Test func makesHostLabels() {
        #expect(MDNSResponder.hostLabel("My NAS.lan") == "My-NAS")
        #expect(MDNSResponder.hostLabel("nas_01.example.com") == "nas-01")
        #expect(MDNSResponder.hostLabel("raspberrypi") == "raspberrypi")
        #expect(MDNSResponder.hostLabel("") == "coolreader")
        #expect(MDNSResponder.hostLabel("___") == "coolreader")
        #expect(!MDNSResponder.hostLabel().isEmpty)
    }

    // MARK: - Over the wire

    /// A query from a port other than 5353 comes from a plain DNS client (RFC 6762 §6.7): the reply goes back to it
    /// by unicast, with its ID and question, TTLs of ten seconds at most and no cache-flush bit. A query for another
    /// service gets no reply at all.
    @Test func answersLegacyUnicastQueries() async throws {
        let responder = MDNSResponder(service: Self.service, port: 0, multicast: false, addresses: [Self.address])
        try responder.start()
        defer { responder.stop() }
        let port = responder.boundPort
        #expect(port != 0 && port != MDNSResponder.port)

        let query = DNSMessage(id: 0x2A2A, flags: 0x0100, questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr)])
        let reply = try DNSMessage(bytes: try #require(await Self.exchange(query.encoded(), port: port)))
        #expect(reply.id == 0x2A2A)
        #expect(reply.isResponse && reply.flags & 0x0400 != 0 && reply.flags & 0x0100 != 0)
        #expect(reply.questions == query.questions)
        #expect(reply.answers.map(\.data) == [DNSMessage.RecordData.ptr(Self.instanceName)])
        #expect(reply.additionals.map(\.data) == [Self.srv.data, Self.txt.data, Self.a.data])
        #expect((reply.answers + reply.additionals).allSatisfy { $0.ttl <= 10 && !$0.cacheFlush })

        let other = DNSMessage(id: 0x2B2B,
                               questions: [DNSMessage.Question(name: DNSMessage.Name(dotted: "_http._tcp.local"), type: DNSMessage.RecordType.ptr)])
        #expect(await Self.exchange(other.encoded(), port: port, timeout: 0.5) == nil)
        #expect(await Self.exchange([0, 1, 2], port: port, timeout: 0.3) == nil)

        // Still there after the silence.
        #expect(await Self.exchange(query.encoded(), port: port) != nil)
    }

    #if os(Linux)
    /// The responder on port 5353 of this machine's network (Docker's, in a container): it probes, announces, answers
    /// a browser by multicast and a plain DNS client by unicast, makes a second server with its name take "(2)", and
    /// says goodbye. It multicasts on the network, so it only runs with COOLREADER_MDNS_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COOLREADER_MDNS_TESTS"] == "1"))
    func multicastsOnTheNetwork() async throws {
        let interface = try #require(MDNSResponder.lanInterfaces().first)
        let listener = try MDNSResponder.Socket(port: MDNSResponder.port)
        defer { listener.close() }
        #expect(listener.join(MDNSResponder.group, on: interface.address) == 0)
        let responder = MDNSResponder(service: Self.service)
        try responder.start()
        defer { responder.stop() }

        let announces: @Sendable (DNSMessage) -> Bool = { message in
            message.isResponse && message.answers.contains { $0.data == .ptr(Self.instanceName) && $0.ttl > 0 }
        }
        let heard = await Self.listen(listener, for: 8) { (messages: [DNSMessage]) -> Bool in messages.filter(announces).count == 3 }
        #expect(heard.filter { !$0.isResponse && $0.questions.first?.name == Self.instanceName }.count == 3)
        let first = heard.first(where: announces)
        let announcement = try #require(first)
        #expect(announcement.answers.contains { $0.data == .a(interface.address) })

        // A browser asks from port 5353, a second after the last announcement: the answer is multicast.
        try await Task.sleep(for: .milliseconds(1100))
        let query = DNSMessage(questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr)])
        listener.send(query.encoded(), to: MDNSResponder.group, port: MDNSResponder.port)
        let answers = await Self.listen(listener, for: 1) { (messages: [DNSMessage]) -> Bool in messages.contains { $0.isResponse } }
        let response = answers.first { $0.isResponse }
        let answer = try #require(response)
        #expect(answer.answers.map(\.data) == [DNSMessage.RecordData.ptr(Self.instanceName)])
        #expect(answer.additionals.map(\.type) == [DNSMessage.RecordType.srv, DNSMessage.RecordType.txt, DNSMessage.RecordType.a])

        // A plain DNS client asks the group from another port: the answer comes back to it by unicast.
        let legacy = DNSMessage(id: 0x3C3C, questions: [DNSMessage.Question(name: Self.typeName, type: DNSMessage.RecordType.ptr)])
        let reply = try DNSMessage(bytes: try #require(await Self.exchange(legacy.encoded(), to: MDNSResponder.group, port: MDNSResponder.port)))
        #expect(reply.id == 0x3C3C && reply.questions == legacy.questions)

        // A second server with the same name finds the first one's records while probing, and takes "(2)".
        var twin = Self.service
        twin.port = 7373
        let second = MDNSResponder(service: twin)
        try second.start()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(second.names.instance == "Cool Reader Test (2)")
        second.stop()

        responder.stop()
        let goodbyes = await Self.listen(listener, for: 1) { (messages: [DNSMessage]) -> Bool in
            messages.contains { $0.answers.contains { $0.data == .ptr(Self.instanceName) && $0.ttl == 0 } }
        }
        #expect(goodbyes.contains { $0.answers.contains { $0.data == .ptr(Self.instanceName) && $0.ttl == 0 } })
    }

    /// The mDNS messages a socket hears within `seconds`, or until `enough` says so.
    static func listen(_ socket: MDNSResponder.Socket, for seconds: Double,
                       until enough: @escaping @Sendable ([DNSMessage]) -> Bool) async -> [DNSMessage] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[DNSMessage], Never>) in
            DispatchQueue.global().async {
                var messages: [DNSMessage] = []
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline, !enough(messages), socket.wait(timeout: deadline.timeIntervalSinceNow) {
                    while let packet = socket.receive() {
                        if let message = try? DNSMessage(bytes: packet.bytes) { messages.append(message) }
                    }
                }
                continuation.resume(returning: messages)
            }
        }
    }
    #endif

    #if canImport(dnssd)
    /// On the Mac the advertiser registers with mDNSResponder: browsing for `_coolreader._tcp` finds it within a few
    /// seconds, resolving it gives its port and TXT record, and it's gone once stopped.
    @Test func registersWithMDNSResponder() async throws {
        let name = "Cool Reader Test \(UUID().uuidString.prefix(8))"
        let advertiser = ServiceAdvertiser(name: name, port: 17272, txt: ["id": Self.serverID, "v": "0.1.0", "api": "1"])
        try advertiser.start()
        defer { advertiser.stop() }
        let browser = try DNSSDBrowser(type: ServiceAdvertiser.serviceType)
        defer { browser.stop() }

        var found: DNSSDBrowser.Service?
        for _ in 0..<50 where found == nil {
            found = browser.services.first { $0.name == name }
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let service = try #require(found)
        let resolution = try DNSSDResolution(service)
        defer { resolution.stop() }
        var resolved: DNSSDResolution.Result?
        for _ in 0..<50 where resolved == nil {
            resolved = resolution.result
            if resolved == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(resolved?.port == 17272)
        #expect(resolved?.txt.sorted() == ["api=1", "id=\(Self.serverID)", "v=0.1.0"])

        advertiser.stop()
        var removed = false
        for _ in 0..<50 where !removed {
            removed = !browser.services.contains { $0.name == name }
            if !removed { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(removed)
    }
    #endif

    // MARK: - Helpers

    static func label(_ text: String) -> [UInt8] {
        [UInt8(text.utf8.count)] + Array(text.utf8)
    }

    static func occurrences(of text: String, in bytes: [UInt8]) -> Int {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count else { return 0 }
        return (0...(bytes.count - needle.count)).filter { (start: Int) -> Bool in Array(bytes[start..<start + needle.count]) == needle }.count
    }

    /// Sends `query` from a socket of its own, to the responder on 127.0.0.1 by default, and waits for one reply.
    static func exchange(_ query: [UInt8], to address: [UInt8] = [127, 0, 0, 1], port: UInt16, timeout: Double = 2) async -> [UInt8]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
            DispatchQueue.global().async {
                guard let socket = try? MDNSResponder.Socket(port: 0) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { socket.close() }
                socket.send(query, to: address, port: port)
                continuation.resume(returning: socket.wait(timeout: timeout) ? socket.receive()?.bytes : nil)
            }
        }
    }
}

extension MDNSResponder.Socket {
    /// Whether a datagram arrives within `timeout` seconds.
    func wait(timeout: Double) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&request, 1, Int32(max(0, timeout) * 1000)) > 0
    }
}

#if canImport(dnssd)
/// dns_sd's browse, which sees the server the way Cool Reader's browser does.
private final class DNSSDBrowser: @unchecked Sendable {
    struct Service: Sendable {
        var name: String
        var type: String
        var domain: String
        var interface: UInt32
    }

    private let queue = DispatchQueue(label: "BonjourTests.browse")
    private let lock = NSLock()
    private var reference: DNSServiceRef?
    private var found: [Service] = []

    var services: [Service] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }

    init(type: String) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceBrowse(&reference, 0, 0, type, nil, { _, flags, interface, error, name, type, domain, context in
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let name, let type, let domain, let context else { return }
            let browser = Unmanaged<DNSSDBrowser>.fromOpaque(context).takeUnretainedValue()
            let service = Service(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), interface: interface)
            browser.lock.lock()
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                browser.found.append(service)
            } else {
                browser.found.removeAll { $0.name == service.name && $0.interface == service.interface }
            }
            browser.lock.unlock()
        }, context)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
            throw ServiceAdvertiser.Failure(description: "browse: \(error)")
        }
        DNSServiceSetDispatchQueue(reference, queue)
    }

    func stop() {
        queue.sync {
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
        }
    }
}

/// dns_sd's resolve: a service's port and TXT strings.
private final class DNSSDResolution: @unchecked Sendable {
    struct Result: Sendable {
        var port: UInt16
        var txt: [String]
    }

    private let queue = DispatchQueue(label: "BonjourTests.resolve")
    private let lock = NSLock()
    private var reference: DNSServiceRef?
    private var value: Result?

    var result: Result? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    init(_ service: DNSSDBrowser.Service) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceResolve(&reference, 0, service.interface, service.name, service.type, service.domain,
                                      { _, _, _, error, _, _, port, length, record, context in
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let context else { return }
            let bytes = record.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
            var strings: [String] = []
            var cursor = 0
            while cursor < bytes.count {
                let count = Int(bytes[cursor])
                strings.append(String(decoding: bytes[(cursor + 1)..<min(bytes.count, cursor + 1 + count)], as: UTF8.self))
                cursor += 1 + count
            }
            let resolution = Unmanaged<DNSSDResolution>.fromOpaque(context).takeUnretainedValue()
            resolution.lock.lock()
            resolution.value = Result(port: UInt16(bigEndian: port), txt: strings)
            resolution.lock.unlock()
        }, context)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
            throw ServiceAdvertiser.Failure(description: "resolve: \(error)")
        }
        DNSServiceSetDispatchQueue(reference, queue)
    }

    func stop() {
        queue.sync {
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
        }
    }
}
#endif
