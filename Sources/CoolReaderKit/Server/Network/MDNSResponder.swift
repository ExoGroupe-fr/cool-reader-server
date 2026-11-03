import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A small Multicast DNS responder (RFC 6762) for one DNS-SD service (RFC 6763), for Linux, where there is no
/// mDNSResponder to register with: a NAS, or Docker with host networking. It shares port 5353 with the machine's own
/// responder (Avahi), probes its names, announces them, answers queries with the records a browser needs next, and
/// says goodbye when it stops. Its socket's reads, its timers and its sends all run on one serial queue.
nonisolated final class MDNSResponder: @unchecked Sendable {
    /// What is advertised.
    nonisolated struct Service: Equatable, Sendable {
        /// The name people see: the server's.
        var instance: String
        /// "_coolreader._tcp".
        var type: String
        /// This machine's label, without ".local".
        var host: String
        var port: UInt16
        /// The TXT record's "key=value" strings.
        var txt: [String]
    }

    static let port: UInt16 = 5353
    static let group: [UInt8] = [224, 0, 0, 251]
    /// A packet fits in a 1500-byte Ethernet frame, IP and UDP headers included.
    static let packetLimit = 1440

    private let queue = DispatchQueue(label: "CoolReader.MDNSResponder")
    private let service: Service
    private let listenPort: UInt16
    private let usesMulticast: Bool
    private let fixedAddresses: [[UInt8]]?

    // The rest is only touched on `queue`.
    private var zone: Zone
    private var udp: Socket?
    private var reader: (any DispatchSourceRead)?
    private var refresher: (any DispatchSourceTimer)?
    private var interfaces: [Interface] = []
    private var localAddresses: Set<[UInt8]> = []
    private var state = State.stopped
    /// Bumped when probing starts over, when announcements start and at stop: older timers see it and do nothing.
    private var generation = 0
    private var probesSent = 0
    private var renames = 0
    private var lastMulticast: [MulticastKey: DispatchTime] = [:]
    private var sentRecently: [(bytes: [UInt8], time: DispatchTime)] = []
    private var warnedNoInterface = false

    private nonisolated enum State { case stopped, probing, announced }

    /// An interface, by name, with its addresses: where multicasts go out.
    private nonisolated struct Link: Sendable {
        var name: String
        var addresses: [[UInt8]]
    }

    private nonisolated struct MulticastKey: Hashable, Sendable {
        var link: String
        var name: DNSMessage.Name
        var data: DNSMessage.RecordData
    }

    /// With `port` 0 and `multicast` false it listens on a port the system picks, for tests that query it directly,
    /// and answers with `addresses` instead of the interfaces' own.
    init(service: Service, port: UInt16 = MDNSResponder.port, multicast: Bool = true, addresses: [[UInt8]]? = nil) {
        self.service = service
        zone = Zone(service: service)
        listenPort = port
        usesMulticast = multicast
        fixedAddresses = addresses
    }

    deinit {
        refresher?.cancel()
        reader?.cancel()
    }

    /// The port it listens on: 5353, or the one the system picked.
    var boundPort: UInt16 {
        queue.sync { udp?.localPort ?? 0 }
    }

    /// The names in use, which change after a conflict: "Name (2)", "host-2".
    var names: (instance: String, host: String) {
        queue.sync { (zone.instance, zone.host) }
    }

    func start() throws {
        try queue.sync {
            guard state == .stopped else { return }
            let udp = try Socket(port: listenPort)
            if usesMulticast { udp.prepareForMulticast() }
            let reader = DispatchSource.makeReadSource(fileDescriptor: udp.descriptor, queue: queue)
            reader.setEventHandler { [weak self] in self?.readPackets() }
            reader.setCancelHandler { udp.close() }
            reader.resume()
            self.udp = udp
            self.reader = reader
            zone = Zone(service: service)
            renames = 0
            guard usesMulticast else {
                state = .announced
                return
            }
            refreshInterfaces()
            let refresher = DispatchSource.makeTimerSource(queue: queue)
            refresher.schedule(deadline: .now() + 30, repeating: 30)
            refresher.setEventHandler { [weak self] in self?.refreshInterfaces() }
            refresher.resume()
            self.refresher = refresher
            startProbing()
        }
    }

    /// Says goodbye, so browsers drop the service at once, and closes the socket.
    func stop() {
        queue.sync {
            guard state != .stopped else { return }
            if state == .announced { sendGoodbyes() }
            state = .stopped
            generation += 1
            refresher?.cancel()
            reader?.cancel()
            refresher = nil
            reader = nil
            udp = nil
            interfaces = []
            lastMulticast = [:]
            sentRecently = []
        }
    }

    // MARK: - Probing and announcing

    private func startProbing() {
        state = .probing
        generation += 1
        probesSent = 0
        let generation = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 0...250))) { [weak self] in self?.probe(generation) }
    }

    /// Three probes 250 ms apart (RFC 6762 §8.1), then the announcements. The probes ask for multicast answers: a
    /// unicast answer to port 5353 could reach Avahi's socket instead of ours.
    private func probe(_ generation: Int) {
        guard generation == self.generation, state == .probing else { return }
        guard probesSent < 3 else {
            finishProbing()
            return
        }
        probesSent += 1
        for link in links() { multicast(zone.probe(addresses: addresses(on: link)), on: link) }
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in self?.probe(generation) }
    }

    private func finishProbing() {
        state = .announced
        let names = links().map(\.name)
        if !names.isEmpty {
            Log.info("Bonjour: advertising « \(zone.instance) » on \(zone.host).local, port \(service.port), on \(names.joined(separator: ", ")).")
        }
        announce()
    }

    /// Three announcements, one then two seconds apart: RFC 6762 §8.3 wants the interval to double after the first.
    private func announce() {
        generation += 1
        let generation = generation
        for delay in [0, 1, 3] {
            queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
                guard let self, generation == self.generation, self.state == .announced else { return }
                for link in self.links() { self.multicast(self.zone.announcement(addresses: self.addresses(on: link)), on: link) }
            }
        }
    }

    private func sendGoodbyes() {
        for link in links() { multicast(zone.goodbye(addresses: addresses(on: link)), on: link) }
    }

    /// A response claiming one of our names with other data: the name gets a number ("Name (2)") and probing starts
    /// over. While probing, an answer for the host name with an address of this machine means its own responder
    /// (Avahi) owns that name: the address records are left to it.
    private func checkConflicts(in response: DNSMessage) {
        let conflicts = zone.conflicts(in: response, addresses: addresses(on: nil), localAddresses: localAddresses)
        if state == .probing, conflicts.hostAnsweredLocally { zone.hostIsShared = true }
        guard conflicts.instance || conflicts.host, renames < 10 else { return }
        renames += 1
        if conflicts.instance {
            let taken = zone.instance
            zone.renameInstance()
            Log.warning("Bonjour: « \(taken) » is taken on the network; this server is advertised as « \(zone.instance) ».")
        }
        if conflicts.host {
            let taken = zone.host
            zone.renameHost()
            Log.warning("Bonjour: another machine is called \(taken).local; this server's records use \(zone.host).local.")
        }
        startProbing()
    }

    /// Lists the interfaces again, at start and every 30 seconds (a DHCP lease, a cable plugged in later): joins the
    /// group on them, and announces the records again when they changed.
    private func refreshInterfaces() {
        localAddresses = Self.localAddresses()
        let current = Self.lanInterfaces()
        guard current != interfaces else { return }
        let hadNone = interfaces.isEmpty
        interfaces = current
        for link in links() {
            let error = udp?.join(Self.group, on: link.addresses[0]) ?? 0
            if error != 0, error != EADDRINUSE {
                Log.warning("Bonjour: can't listen for queries on \(link.name) (\(String(cString: strerror(error)))).")
            }
        }
        if current.isEmpty {
            if !warnedNoInterface { Log.warning("Bonjour: no network interface to advertise the server on yet.") }
            warnedNoInterface = true
            return
        }
        warnedNoInterface = false
        if state == .announced { hadNone ? startProbing() : announce() }
    }

    // MARK: - Queries

    private func readPackets() {
        guard let udp else { return }
        for _ in 0..<64 {
            guard let packet = udp.receive() else { return }
            guard !isEcho(packet.bytes), let message = try? DNSMessage(bytes: packet.bytes) else { continue }
            handle(message, from: packet.address, port: packet.port)
        }
    }

    private func handle(_ message: DNSMessage, from source: [UInt8], port: UInt16) {
        guard state != .stopped, message.opcode == 0, message.responseCode == 0, isOnLink(source) else { return }
        if message.isResponse {
            // Responses only count from port 5353 (RFC 6762 §6).
            if port == Self.port { checkConflicts(in: message) }
        } else if state == .announced {
            answer(message, from: source, port: port)
        }
    }

    private func answer(_ query: DNSMessage, from source: [UInt8], port: UInt16) {
        let link = link(for: source)
        if port != Self.port {
            // A plain DNS client's query (RFC 6762 §6.7): answered like a DNS server would, by unicast, with its ID and
            // question, short TTLs and no cache-flush bit.
            guard let reply = zone.answer(query, addresses: addresses(on: link)) else { return }
            let legacy: (DNSMessage.Record) -> DNSMessage.Record = { record in
                var record = record
                record.cacheFlush = false
                record.ttl = min(record.ttl, 10)
                return record
            }
            send(DNSMessage(id: query.id, flags: DNSMessage.responseFlags | (query.flags & 0x0100), questions: query.questions,
                            answers: reply.answers.map(legacy), additionals: reply.additionals.map(legacy)), to: source, port: port)
            return
        }
        // "QU" questions get a unicast reply, unless a record hasn't been multicast for a quarter of its TTL: then
        // every cache on the link gets it (RFC 6762 §5.4).
        if query.questions.allSatisfy(\.unicastResponse), let reply = zone.answer(query, addresses: addresses(on: link)) {
            let recent = reply.answers.allSatisfy { (record: DNSMessage.Record) -> Bool in
                wasMulticast(record, on: link?.name, within: Double(record.ttl) / 4)
            }
            if recent {
                send(DNSMessage(id: query.id, flags: DNSMessage.responseFlags, answers: reply.answers, additionals: reply.additionals),
                     to: source, port: port)
                return
            }
        }
        // Multicast, on the link the query came through, or on each one when that's unclear.
        let isProbe = !query.authorities.isEmpty
        for target in link.map({ [$0] }) ?? links() {
            guard let reply = zone.answer(query, addresses: addresses(on: target)) else { continue }
            // Shared records (the PTR) wait 20 to 120 ms so that several servers' answers don't collide (RFC 6762 §6).
            let delay = reply.answers.contains(where: { !$0.cacheFlush }) ? Int.random(in: 20...120) : 0
            let generation = generation
            queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self, generation == self.generation, self.state == .announced else { return }
                // A record goes out at most once a second on a link, or every 250 ms to defend a name against a probe.
                let fresh = reply.answers.filter { (record: DNSMessage.Record) -> Bool in
                    !self.wasMulticast(record, on: target.name, within: isProbe ? 0.25 : 1)
                }
                guard !fresh.isEmpty else { return }
                self.multicast(DNSMessage(flags: DNSMessage.responseFlags, answers: fresh, additionals: reply.additionals), on: target)
            }
        }
    }

    /// mDNS stays on the local link (RFC 6762 §11): packets from elsewhere, such as unicast queries from the internet
    /// to a server with a public address, are ignored.
    private func isOnLink(_ source: [UInt8]) -> Bool {
        guard source.count == 4 else { return false }
        if source[0] == 127 || (source[0] == 169 && source[1] == 254) { return true }
        return interfaces.contains { $0.contains(source) }
    }

    /// The link a packet from `source` came through, judged by subnet: the socket doesn't say.
    private func link(for source: [UInt8]) -> Link? {
        guard let interface = interfaces.first(where: { $0.contains(source) }) else { return nil }
        return links().first { $0.name == interface.name }
    }

    private func links() -> [Link] {
        var links: [Link] = []
        for interface in interfaces {
            if let index = links.firstIndex(where: { $0.name == interface.name }) {
                links[index].addresses.append(interface.address)
            } else {
                links.append(Link(name: interface.name, addresses: [interface.address]))
            }
        }
        return links
    }

    /// The addresses to give on a link: its own (RFC 6762 §15), all of them when the link is unknown, or the test's.
    private func addresses(on link: Link?) -> [[UInt8]] {
        fixedAddresses ?? link?.addresses ?? interfaces.map(\.address)
    }

    // MARK: - Sending

    private func multicast(_ message: DNSMessage, on link: Link) {
        guard let udp, let address = link.addresses.first else { return }
        let bytes = message.encoded(limit: Self.packetLimit)
        udp.setMulticastInterface(address)
        udp.send(bytes, to: Self.group, port: Self.port)
        let now = DispatchTime.now()
        sentRecently.append((bytes, now))
        if sentRecently.count > 32 { sentRecently.removeFirst(sentRecently.count - 32) }
        for record in message.answers { lastMulticast[MulticastKey(link: link.name, name: record.name, data: record.data)] = now }
    }

    private func send(_ message: DNSMessage, to address: [UInt8], port: UInt16) {
        udp?.send(message.encoded(limit: Self.packetLimit), to: address, port: port)
    }

    private func wasMulticast(_ record: DNSMessage.Record, on link: String?, within seconds: Double) -> Bool {
        guard let link, let time = lastMulticast[MulticastKey(link: link, name: record.name, data: record.data)] else { return false }
        return Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) < seconds * 1e9
    }

    /// Our own multicasts come back to us (multicast loopback stays on, for browsers on this machine): they're
    /// recognised by their bytes and ignored.
    private func isEcho(_ bytes: [UInt8]) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        sentRecently.removeAll { now - $0.time.uptimeNanoseconds > 5_000_000_000 }
        return sentRecently.contains { $0.bytes == bytes }
    }
}

nonisolated extension MDNSResponder {
    /// The records the responder owns, and how it answers with them. No sockets: tests read it directly.
    nonisolated struct Zone: Sendable {
        let service: Service
        /// The names in use: the service's, or "Name (2)" and "host-2" after conflicts.
        private(set) var instance: String
        private(set) var host: String
        /// This machine's own responder (Avahi) answers for the host name: the address records are left to it.
        var hostIsShared = false
        private var instanceNumber = 1
        private var hostNumber = 1

        /// DNS-SD's list of service types (RFC 6763 §9).
        static let servicesName = DNSMessage.Name(dotted: "_services._dns-sd._udp.local")

        init(service: Service) {
            self.service = service
            instance = DNSMessage.Name.label(service.instance)
            host = DNSMessage.Name.label(service.host)
        }

        var typeName: DNSMessage.Name { DNSMessage.Name(dotted: service.type + ".local") }
        var instanceName: DNSMessage.Name { DNSMessage.Name([instance] + typeName.labels) }
        var hostName: DNSMessage.Name { DNSMessage.Name([host, "local"]) }

        /// The service's records, with the TTLs RFC 6762 §10 recommends: two minutes for those naming a host, 75
        /// minutes for the others. The cache-flush bit marks those no other server shares.
        func records(addresses: [[UInt8]]) -> [DNSMessage.Record] {
            var records = [
                DNSMessage.Record(name: typeName, ttl: 4500, data: .ptr(instanceName)),
                DNSMessage.Record(name: instanceName, ttl: 120, data: .srv(priority: 0, weight: 0, port: service.port, target: hostName),
                                  cacheFlush: true),
                DNSMessage.Record(name: instanceName, ttl: 4500, data: .txt(service.txt), cacheFlush: true),
                DNSMessage.Record(name: Self.servicesName, ttl: 4500, data: .ptr(typeName)),
            ]
            if !hostIsShared {
                records += addresses.map { (address: [UInt8]) -> DNSMessage.Record in
                    DNSMessage.Record(name: hostName, ttl: 120, data: .a(address), cacheFlush: true)
                }
            }
            return records
        }

        /// The answers to a query, with the records that go with them (RFC 6763 §12): the service's SRV, TXT and
        /// addresses with its PTR, the addresses with its SRV. Nil when the query isn't about this service. Records
        /// the querier already knows, with at least half their TTL left, are left out (RFC 6762 §7.1).
        func answer(_ query: DNSMessage, addresses: [[UInt8]]) -> (answers: [DNSMessage.Record], additionals: [DNSMessage.Record])? {
            let records = self.records(addresses: addresses)
            let isKnown: (DNSMessage.Record) -> Bool = { record in
                query.answers.contains { $0.isSame(as: record) && $0.ttl >= record.ttl / 2 }
            }
            var answers: [DNSMessage.Record] = []
            for question in query.questions where question.recordClass == 1 || question.recordClass == 255 {
                for record in records where record.name == question.name {
                    guard question.type == record.type || question.type == DNSMessage.RecordType.any else { continue }
                    if !isKnown(record), !answers.contains(record) { answers.append(record) }
                }
            }
            guard !answers.isEmpty else { return nil }
            var additionals: [DNSMessage.Record] = []
            for answer in answers {
                var names: [DNSMessage.Name] = []
                if case .ptr(let target) = answer.data, target == instanceName { names = [instanceName, hostName] }
                if case .srv = answer.data { names = [hostName] }
                for record in records where names.contains(record.name) {
                    if !answers.contains(record), !additionals.contains(record), !isKnown(record) { additionals.append(record) }
                }
            }
            return (answers, additionals)
        }

        /// "Is anyone using these names?", with the records we'd like in the authority section (RFC 6762 §8.1); a
        /// query's records have no cache-flush bit (§18.13).
        func probe(addresses: [[UInt8]]) -> DNSMessage {
            var questions = [DNSMessage.Question(name: instanceName, type: DNSMessage.RecordType.any)]
            if !hostIsShared { questions.append(DNSMessage.Question(name: hostName, type: DNSMessage.RecordType.any)) }
            let claimed = records(addresses: addresses).filter { $0.name == instanceName || $0.name == hostName }
            return DNSMessage(questions: questions, authorities: claimed.map { (record: DNSMessage.Record) -> DNSMessage.Record in
                var record = record
                record.cacheFlush = false
                return record
            })
        }

        func announcement(addresses: [[UInt8]]) -> DNSMessage {
            DNSMessage(flags: DNSMessage.responseFlags, answers: records(addresses: addresses))
        }

        /// The records with a TTL of zero, so caches drop them (RFC 6762 §10.1). Without the cache-flush bit: the
        /// goodbye of an address record must not flush Avahi's for the same host name.
        func goodbye(addresses: [[UInt8]]) -> DNSMessage {
            var message = announcement(addresses: addresses)
            message.answers = message.answers.map { (record: DNSMessage.Record) -> DNSMessage.Record in
                var record = record
                record.ttl = 0
                record.cacheFlush = false
                return record
            }
            return message
        }

        nonisolated struct Conflicts: Equatable, Sendable {
            /// Another server answers for the instance name with other data.
            var instance = false
            /// Another machine answers for the host name.
            var host = false
            /// This machine's own responder answers for the host name.
            var hostAnsweredLocally = false
        }

        /// What a response says about our names. Records identical to ours are no conflict (RFC 6762 §9), nor is an
        /// address of this machine for the host name: that's its own responder, not another machine of that name.
        func conflicts(in response: DNSMessage, addresses: [[UInt8]], localAddresses: Set<[UInt8]>) -> Conflicts {
            let ours = records(addresses: addresses)
            var conflicts = Conflicts()
            for record in response.answers + response.additionals where record.ttl > 0 {
                if record.name == instanceName, record.type == DNSMessage.RecordType.srv || record.type == DNSMessage.RecordType.txt {
                    if !ours.contains(where: { $0.isSame(as: record) }) { conflicts.instance = true }
                } else if record.name == hostName, case .a(let address) = record.data {
                    if localAddresses.contains(address) || addresses.contains(address) {
                        conflicts.hostAnsweredLocally = true
                    } else {
                        conflicts.host = true
                    }
                }
            }
            return conflicts
        }

        mutating func renameInstance() {
            instanceNumber += 1
            instance = DNSMessage.Name.label(service.instance, suffix: " (\(instanceNumber))")
        }

        mutating func renameHost() {
            hostNumber += 1
            host = DNSMessage.Name.label(service.host, suffix: "-\(hostNumber)")
        }
    }

    // MARK: - Interfaces and host name

    /// An IPv4 address of a network interface.
    nonisolated struct Interface: Equatable, Sendable {
        var name: String
        var address: [UInt8]
        var netmask: [UInt8]

        /// Whether `other` is on this address's subnet.
        func contains(_ other: [UInt8]) -> Bool {
            guard other.count == 4, address.count == 4, netmask.count == 4 else { return false }
            return (0..<4).allSatisfy { (index: Int) -> Bool in address[index] & netmask[index] == other[index] & netmask[index] }
        }
    }

    /// Virtual interfaces, by the start of their names: container and virtual machine bridges, veths, VPN tunnels.
    static let virtualInterfacePrefixes = ["docker", "br-", "veth", "cni", "flannel", "lxcbr", "lxdbr", "virbr", "vmnet", "vboxnet", "bridge",
                                           "utun", "tailscale", "zt", "wg"]

    /// The interfaces the service is advertised on: up, running, multicast, IPv4; not loopback, point-to-point,
    /// link-local (169.254/16) or virtual.
    static func lanInterfaces() -> [Interface] {
        let required = UInt32(IFF_UP) | UInt32(IFF_RUNNING) | UInt32(IFF_MULTICAST)
        let excluded = UInt32(IFF_LOOPBACK) | UInt32(IFF_POINTOPOINT)
        var interfaces: [Interface] = []
        for (interface, flags) in ipv4Interfaces() {
            guard flags & required == required, flags & excluded == 0, interface.address[0] != 127,
                  !(interface.address[0] == 169 && interface.address[1] == 254),
                  !virtualInterfacePrefixes.contains(where: { interface.name.hasPrefix($0) }) else { continue }
            interfaces.append(interface)
        }
        return interfaces
    }

    /// Every IPv4 address of this machine, loopback and virtual ones too: an answer giving one of them for our host
    /// name comes from this machine's own responder, not from another machine with the same name.
    static func localAddresses() -> Set<[UInt8]> {
        Set(ipv4Interfaces().map { $0.interface.address })
    }

    private static func ipv4Interfaces() -> [(interface: Interface, flags: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(interface: Interface, flags: UInt32)] = []
        var cursor = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let netmask = entry.pointee.ifa_netmask.map { Socket.bytes(of: $0) } ?? [255, 255, 255, 255]
            let name = String(cString: entry.pointee.ifa_name)
            result.append((Interface(name: name, address: Socket.bytes(of: address), netmask: netmask), entry.pointee.ifa_flags))
        }
        return result
    }

    /// This machine's name as a host label: its first part, in letters, digits and hyphens ("My-NAS" for
    /// "My NAS.lan"). A Docker container with host networking has the host's name.
    static func hostLabel(_ hostname: String = MDNSResponder.systemHostName()) -> String {
        var label = ""
        for byte in (hostname.split(separator: ".").first ?? "").utf8.prefix(63) {
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) {
                label.append(Character(Unicode.Scalar(byte)))
            } else if !label.isEmpty, !label.hasSuffix("-") {
                label.append("-")
            }
        }
        while label.hasSuffix("-") { label.removeLast() }
        return label.isEmpty ? "coolreader" : label
    }

    static func systemHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Socket

    nonisolated struct SocketError: Error, CustomStringConvertible {
        var operation: String
        var code: Int32

        var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
    }

    /// A non-blocking IPv4 UDP socket with the options mDNS wants.
    nonisolated struct Socket: Sendable {
        let descriptor: Int32

        /// Binds `port` on every address. SO_REUSEADDR and SO_REUSEPORT let it share 5353 with Avahi.
        init(port: UInt16) throws {
            let descriptor = Self.openDescriptor()
            guard descriptor >= 0 else { throw SocketError(operation: "socket", code: errno) }
            var one: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = Self.socketAddress([0, 0, 0, 0], port: port)
            let bound = withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_in>) -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else {
                let code = errno
                Self.closeDescriptor(descriptor)
                throw SocketError(operation: "bind to port \(port)", code: code)
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            self.descriptor = descriptor
        }

        /// Every packet goes out with a TTL of 255 (RFC 6762 §11). Multicast loopback stays on: browsers on this
        /// machine see the service too.
        func prepareForMulticast() {
            var hops: UInt8 = 255
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &hops, socklen_t(1))
            var ttl: Int32 = 255
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        }

        /// Joins `group` on the interface that has `address`. Returns the error, or 0.
        func join(_ group: [UInt8], on address: [UInt8]) -> Int32 {
            var request = ip_mreq(imr_multiaddr: Self.inAddress(group), imr_interface: Self.inAddress(address))
            let result = setsockopt(descriptor, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
            return result == 0 ? 0 : errno
        }

        /// Multicasts go out on the interface that has `address`.
        func setMulticastInterface(_ address: [UInt8]) {
            var value = Self.inAddress(address)
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_MULTICAST_IF, &value, socklen_t(MemoryLayout<in_addr>.size))
        }

        @discardableResult
        func send(_ bytes: [UInt8], to address: [UInt8], port: UInt16) -> Bool {
            var destination = Self.socketAddress(address, port: port)
            let sent = withUnsafePointer(to: &destination) { (pointer: UnsafePointer<sockaddr_in>) -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { (target: UnsafePointer<sockaddr>) -> Int in
                    bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
                        sendto(descriptor, buffer.baseAddress, buffer.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return sent == bytes.count
        }

        /// The next datagram waiting and who sent it, or nil when there's none.
        func receive() -> (bytes: [UInt8], address: [UInt8], port: UInt16)? {
            var buffer = [UInt8](repeating: 0, count: 9000)
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                withUnsafeMutablePointer(to: &source) { (pointer: UnsafeMutablePointer<sockaddr_in>) -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, raw.baseAddress, raw.count, 0, $0, &length) }
                }
            }
            guard count >= 0 else { return nil }
            return (Array(buffer.prefix(count)), Self.bytes(source.sin_addr), UInt16(bigEndian: source.sin_port))
        }

        var localPort: UInt16 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { (pointer: UnsafeMutablePointer<sockaddr_in>) -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            return UInt16(bigEndian: address.sin_port)
        }

        func close() {
            Self.closeDescriptor(descriptor)
        }

        static func bytes(of address: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { bytes($0.pointee.sin_addr) }
        }

        static func bytes(_ address: in_addr) -> [UInt8] {
            let value = UInt32(bigEndian: address.s_addr)
            return [24, 16, 8, 0].map { (shift: UInt32) -> UInt8 in UInt8(truncatingIfNeeded: value >> shift) }
        }

        static func inAddress(_ bytes: [UInt8]) -> in_addr {
            let value = bytes.prefix(4).reduce(UInt32(0)) { (value: UInt32, byte: UInt8) -> UInt32 in value << 8 | UInt32(byte) }
            return in_addr(s_addr: value.bigEndian)
        }

        static func socketAddress(_ bytes: [UInt8], port: UInt16) -> sockaddr_in {
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = inAddress(bytes)
            return address
        }

        private static func openDescriptor() -> Int32 {
            #if canImport(Darwin)
            return Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            #else
            return Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            #endif
        }

        private static func closeDescriptor(_ descriptor: Int32) {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #else
            _ = Glibc.close(descriptor)
            #endif
        }
    }
}
