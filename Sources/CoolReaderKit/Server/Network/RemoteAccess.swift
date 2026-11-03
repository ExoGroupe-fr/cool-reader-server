import Foundation

/// What the admin chose for access from outside the home.
nonisolated struct RemoteAccessSettings: Codable, Sendable, Equatable {
    /// Opens the port on the router by itself: NAT-PMP, else UPnP.
    var isEnabled = false
    /// The port asked for on the router; nil: the server's own.
    var externalPort: Int?
    /// A name or address the user set up themselves (their own domain, a port forwarded by hand), with ":port" when
    /// it differs from `externalPort`. It wins over what is discovered and comes first in invitations.
    var publicHost: String?
    /// "myname" or "myname.duckdns.org", kept pointing at the home with `duckDNSToken`.
    var duckDNSDomain: String?
    var duckDNSToken: String?
}

extension RemoteAccessSettings {
    /// Missing keys keep their defaults: settings saved by an older version still load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        externalPort = try container.decodeIfPresent(Int.self, forKey: .externalPort)
        publicHost = try container.decodeIfPresent(String.self, forKey: .publicHost)
        duckDNSDomain = try container.decodeIfPresent(String.self, forKey: .duckDNSDomain)
        duckDNSToken = try container.decodeIfPresent(String.self, forKey: .duckDNSToken)
    }
}

/// Where remote access stands, for the admin page.
nonisolated struct RemoteAccessStatus: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case off, working, open, manual, failed }
    enum Problem: String, Codable, Sendable { case noGateway, noRouterSupport, routerRefused, sharedAddress, portTaken, duckDNSFailed }

    var state: State
    /// "NAT-PMP" or "UPnP": the one that opened the port, or that gave the shared address.
    var method: String?
    /// This machine on the LAN: where the router forwards.
    var localAddress: String?
    var gateway: String?
    var externalPort: Int?
    /// The router's WAN address.
    var publicAddress: String?
    /// The user's own host, else the DuckDNS name.
    var publicHost: String?
    var problem: Problem?
    /// The router's or DuckDNS's error, for the admin. Never the token.
    var detail: String?
    var updatedAt: Date
}

/// Access from outside the home with a direct connection and no relay: opens the server's port on the router
/// (NAT-PMP, else UPnP), learns the public address, says when the router is itself behind another NAT (CGNAT,
/// double NAT) and no port can be opened from here, and keeps a DuckDNS name up to date. A VPN stays the user's own
/// fallback. `status` is for the admin page, `publicEndpoints` for invitations.
actor RemoteAccess {
    /// Where the router and DuckDNS are: the real ones, or tests' fakes on 127.0.0.1.
    struct Environment: Sendable {
        var gateway: @Sendable () -> String? = { NetworkInterfaces.defaultGateway() }
        var natPMPPort = NATPMP.port
        var ssdpAddress = UPnP.ssdpAddress
        var ssdpPort = UPnP.ssdpPort
        var duckDNSURL = DuckDNS.updateURL
        /// Between two looks at the router and two DuckDNS updates.
        var refreshInterval: Duration = .seconds(300)
    }

    /// The port this server opened on the router, to renew and to remove.
    private struct Mapping: Sendable {
        enum Method: Sendable {
            case natPMP
            case upnp(UPnP.Service)
        }

        var method: Method
        var gateway: String
        var client: String
        var requestedPort: Int
        var externalPort: Int
        var renewAt: Date
        /// NAT-PMP's epoch and when it was read.
        var epoch: (value: UInt32, readAt: Date)?

        var methodName: String {
            if case .natPMP = method { return "NAT-PMP" }
            return "UPnP"
        }
    }

    private enum Outcome {
        case opened(Mapping, publicAddress: String?)
        case shared(publicAddress: String, method: String)
        case failed(RemoteAccessStatus.Problem, detail: String?)
    }

    private let localPort: Int
    private let mappingDescription: String
    private let environment: Environment
    private var settings: RemoteAccessSettings
    private(set) var status = RemoteAccessStatus(state: .off, updatedAt: Date())
    private var mapping: Mapping?
    /// The DuckDNS name once DuckDNS took an update with the current settings, and why the last update failed.
    private var duckDNSHost: String?
    private var duckDNSFailure: String?
    private var task: Task<Void, Never>?

    init(localPort: Int, settings: RemoteAccessSettings, description: String = "Cool Reader Server",
         environment: Environment = Environment()) {
        self.localPort = localPort
        self.settings = settings
        self.mappingDescription = description
        self.environment = environment
    }

    /// Applies the settings, then keeps them applied: renews the mapping before its lease ends, notices a new
    /// public address or a router that restarted, tries again after a failure, and updates DuckDNS every 5 minutes.
    func start() {
        schedule()
    }

    /// Applies new settings; turning remote access off removes the mapping.
    func update(_ settings: RemoteAccessSettings) {
        guard settings != self.settings else { return }
        if settings.duckDNSDomain != self.settings.duckDNSDomain || settings.duckDNSToken != self.settings.duckDNSToken {
            duckDNSHost = nil
            duckDNSFailure = nil
        }
        self.settings = settings
        if task != nil { schedule() }
    }

    /// Removes the mapping: the server is stopping.
    func stop() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        await removeMapping()
        publish(RemoteAccessStatus(state: .off, updatedAt: Date()))
    }

    /// "host:port" for invitations, best first: the user's host, the DuckDNS name, then the public address. Empty
    /// unless the port is open, or the user opened it.
    var publicEndpoints: [String] {
        guard status.state == .open || status.state == .manual else { return [] }
        let port = status.externalPort ?? wantedPort
        var hosts: [String] = []
        if let host = Self.text(settings.publicHost) { hosts.append(host) }
        if let host = duckDNSHost { hosts.append(host) }
        if status.state == .open, let address = status.publicAddress { hosts.append(address) }
        var endpoints: [String] = []
        for host in hosts {
            let endpoint = Self.endpoint(host, port: port)
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
        return endpoints
    }

    /// "host:port" from what the user typed: a scheme and a path are dropped, a port they gave is kept, and an IPv6
    /// address gets its brackets.
    static func endpoint(_ host: String, port: Int) -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { $0 != "/" })
        if host.hasPrefix("[") { return host.contains("]:") ? host : "\(host):\(port)" }
        switch host.filter({ $0 == ":" }).count {
        case 0: return "\(host):\(port)"
        case 1: return host
        default: return "[\(host)]:\(port)"
        }
    }

    private var wantedPort: Int {
        guard let port = settings.externalPort, (1...65535).contains(port) else { return localPort }
        return port
    }

    /// Starts applying the current settings once the previous run has stopped: it may be in the middle of an
    /// exchange with the router, and what it opened must be known before deciding what to remove.
    private func schedule() {
        let previous = task
        previous?.cancel()
        if settings.isEnabled {
            var working = status
            working.state = .working
            working.problem = nil
            working.detail = nil
            publish(working)
        } else {
            let gateway = environment.gateway()
            publish(idleStatus(gateway: gateway, local: gateway.flatMap(NetworkInterfaces.localAddress(toward:))))
        }
        task = Task {
            await previous?.value
            await run()
        }
    }

    private func run() async {
        await apply()
        while !Task.isCancelled, settings.isEnabled || duckDNSWanted {
            try? await Task.sleep(for: pause())
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Applies the settings from scratch: removes a mapping that is no longer wanted, asks the router (NAT-PMP,
    /// then UPnP), updates DuckDNS, and publishes what came of it.
    private func apply() async {
        let settings = self.settings
        let wanted = wantedPort
        let gateway = environment.gateway()
        let local = gateway.flatMap(NetworkInterfaces.localAddress(toward:))
        if let mapping, !settings.isEnabled || mapping.gateway != gateway || mapping.client != local || mapping.requestedPort != wanted {
            await removeMapping()
        }
        guard settings.isEnabled else {
            await updateDuckDNS()
            guard !Task.isCancelled else { return }
            publish(idleStatus(gateway: gateway, local: local))
            return
        }
        var next = RemoteAccessStatus(state: .failed, localAddress: local ?? NetworkInterfaces.localAddresses().first, gateway: gateway,
                                      updatedAt: Date())
        if let gateway, let local {
            switch await openPort(gateway: gateway, client: local, wanted: wanted) {
            case .opened(let opened, let publicAddress):
                // Kept even when this run was cancelled meanwhile: the next run, or stop(), removes it.
                mapping = opened
                next.state = .open
                next.method = opened.methodName
                next.externalPort = opened.externalPort
                next.publicAddress = publicAddress
            case .shared(let publicAddress, let method):
                // A port opened on a router that is behind another NAT would stay closed from outside.
                await removeMapping()
                next.method = method
                next.publicAddress = publicAddress
                next.problem = .sharedAddress
            case .failed(let problem, let detail):
                await removeMapping()
                next.problem = problem
                next.detail = detail ?? Self.containerHint(gateway: gateway, problem: problem)
            }
        } else {
            next.problem = .noGateway
        }
        guard !Task.isCancelled else { return }
        await updateDuckDNS()
        guard !Task.isCancelled else { return }
        publish(next)
    }

    /// NAT-PMP first, then UPnP. When both fail, a router that refused says more than one that didn't answer.
    private func openPort(gateway: String, client: String, wanted: Int) async -> Outcome {
        let natPMP = await openWithNATPMP(gateway: gateway, client: client, wanted: wanted)
        guard case .failed(let problem, _) = natPMP, !Task.isCancelled else { return natPMP }
        let upnp = await openWithUPnP(gateway: gateway, client: client, wanted: wanted)
        if case .failed(.noRouterSupport, _) = upnp, problem != .noRouterSupport { return natPMP }
        return upnp
    }

    private func openWithNATPMP(gateway: String, client: String, wanted: Int) async -> Outcome {
        let port = environment.natPMPPort
        do {
            let external = try await NATPMP.externalAddress(gateway: gateway, port: port)
            let address = Self.publicAddress(external.address)
            if let address, Self.isShared(address) { return .shared(publicAddress: address, method: "NAT-PMP") }
            let granted = try await NATPMP.map(internalPort: localPort, externalPort: wanted, lifetime: NATPMP.lifetime,
                                               gateway: gateway, port: port)
            let mapping = Mapping(method: .natPMP, gateway: gateway, client: client, requestedPort: wanted,
                                  externalPort: granted.externalPort,
                                  renewAt: Date().addingTimeInterval(Self.renewal(after: granted.lifetime)),
                                  epoch: (granted.epoch, Date()))
            return .opened(mapping, publicAddress: address)
        } catch NATPMP.Failure.refused(let code) {
            return .failed(.routerRefused, detail: NATPMP.describe(code))
        } catch {
            return .failed(.noRouterSupport, detail: nil)
        }
    }

    private func openWithUPnP(gateway: String, client: String, wanted: Int) async -> Outcome {
        let locations = await UPnP.discover(gateway: gateway, address: environment.ssdpAddress, port: environment.ssdpPort)
        let connection: UPnP.Connection
        switch await UPnP.connection(locations: locations) {
        case .success(let found): connection = found
        case .failure(let failure): return Self.outcome(failure, port: wanted)
        }
        let address = connection.externalAddress.flatMap(Self.publicAddress)
        if let address, Self.isShared(address) { return .shared(publicAddress: address, method: "UPnP") }
        let added = await UPnP.addMapping(on: connection.service, externalPort: wanted, internalPort: localPort, client: client,
                                          description: mappingDescription)
        switch added {
        case .success(let opened):
            let mapping = Mapping(method: .upnp(connection.service), gateway: gateway, client: client, requestedPort: wanted,
                                  externalPort: opened.externalPort, renewAt: Date().addingTimeInterval(Self.renewal(after: opened.lease)),
                                  epoch: nil)
            return .opened(mapping, publicAddress: address)
        case .failure(let failure):
            return Self.outcome(failure, port: wanted)
        }
    }

    private static func outcome(_ failure: UPnP.Failure, port: Int) -> Outcome {
        switch failure {
        case .notFound: .failed(.noRouterSupport, detail: nil)
        case .noAnswer(let text): .failed(.routerRefused, detail: "UPnP: \(text)")
        case .fault(let code, let description): .failed(.routerRefused, detail: "UPnP error \(code) \(description)")
        case .portTaken(let owner): .failed(.portTaken, detail: "port \(port) is forwarded to \(owner)")
        }
    }

    /// Closes the port this server opened, if it did. Best effort: a router that is gone took the mapping with it.
    private func removeMapping() async {
        guard let mapping else { return }
        self.mapping = nil
        switch mapping.method {
        case .natPMP:
            _ = try? await NATPMP.map(internalPort: localPort, externalPort: 0, lifetime: 0, gateway: mapping.gateway,
                                      port: environment.natPMPPort)
        case .upnp(let service):
            await UPnP.deleteMapping(on: service, externalPort: mapping.externalPort, internalPort: localPort, client: mapping.client)
        }
    }

    /// Every few minutes: everything again when the mapping is due for renewal, missing, or behind another gateway;
    /// otherwise a look at the router's WAN address (NAT-PMP's answer also tells a router that restarted and lost
    /// the mapping). Then DuckDNS.
    private func refresh() async {
        guard settings.isEnabled, let mapping, status.state == .open, environment.gateway() == mapping.gateway,
              Date() < mapping.renewAt else {
            await apply()
            return
        }
        let address: String?
        switch mapping.method {
        case .natPMP:
            guard let external = try? await NATPMP.externalAddress(gateway: mapping.gateway, port: environment.natPMPPort) else {
                await apply()
                return
            }
            if let epoch = mapping.epoch, Self.routerRestarted(previous: epoch.value, readAt: epoch.readAt, epoch: external.epoch) {
                await apply()
                return
            }
            self.mapping?.epoch = (external.epoch, Date())
            address = Self.publicAddress(external.address)
        case .upnp(let service):
            guard case .success(let found) = await UPnP.externalAddress(on: service) else {
                await apply()
                return
            }
            address = found.flatMap(Self.publicAddress)
        }
        if let address, Self.isShared(address) {
            await apply()
            return
        }
        guard !Task.isCancelled else { return }
        await updateDuckDNS()
        guard !Task.isCancelled else { return }
        var next = status
        next.publicAddress = address
        next.problem = nil
        next.detail = nil
        publish(next)
    }

    /// DuckDNS gets an update when its domain and token are set and remote access is on, opened here or by hand.
    private func updateDuckDNS() async {
        let settings = self.settings
        guard settings.isEnabled || Self.text(settings.publicHost) != nil,
              let domain = Self.text(settings.duckDNSDomain), let token = Self.text(settings.duckDNSToken) else {
            duckDNSHost = nil
            duckDNSFailure = nil
            return
        }
        let failure = await DuckDNS.update(domain: domain, token: token, base: environment.duckDNSURL)
        guard settings == self.settings else { return }
        if let failure {
            duckDNSFailure = DuckDNS.describe(failure)
        } else {
            duckDNSHost = DuckDNS.host(domain)
            duckDNSFailure = nil
        }
    }

    /// The user opened the port themselves and DuckDNS follows the address.
    private var duckDNSWanted: Bool {
        Self.text(settings.publicHost) != nil && Self.text(settings.duckDNSDomain) != nil && Self.text(settings.duckDNSToken) != nil
    }

    private func pause() -> Duration {
        guard let mapping else { return environment.refreshInterval }
        return min(environment.refreshInterval, .seconds(max(1, mapping.renewAt.timeIntervalSinceNow)))
    }

    /// Off, or manual when the user opened the port themselves.
    private func idleStatus(gateway: String?, local: String?) -> RemoteAccessStatus {
        let manual = Self.text(settings.publicHost) != nil
        return RemoteAccessStatus(state: manual ? .manual : .off, localAddress: local, gateway: gateway,
                                  externalPort: manual ? wantedPort : nil, updatedAt: Date())
    }

    /// Sets the status with what DuckDNS adds, and logs a line when something the admin cares about changed.
    private func publish(_ next: RemoteAccessStatus) {
        var next = next
        next.publicHost = Self.text(settings.publicHost) ?? duckDNSHost
        if next.problem == nil, next.state == .open || next.state == .manual, let failure = duckDNSFailure {
            next.problem = .duckDNSFailed
            next.detail = failure
        }
        next.updatedAt = Date()
        let previous = status
        status = next
        guard next.state != .working, Self.summary(next) != Self.summary(previous) else { return }
        let reachable = publicEndpoints.first.map { ", reachable at \($0)" } ?? ""
        let detail = next.detail.map { " (\($0))" } ?? ""
        switch next.state {
        case .working:
            break
        case .off:
            Log.info("Remote access is off.")
        case .open, .manual:
            let how = next.state == .open ? "port \(next.externalPort ?? 0) opened on the router with \(next.method ?? "?")" : "set up by hand"
            if next.problem == .duckDNSFailed {
                Log.warning("Remote access: \(how)\(reachable), but the DuckDNS update failed\(detail).")
            } else {
                Log.info("Remote access: \(how)\(reachable).")
            }
        case .failed:
            Log.warning("Remote access failed: \(Self.explanation(next))\(detail).")
        }
    }

    private static func summary(_ status: RemoteAccessStatus) -> [String?] {
        [status.state.rawValue, status.method, status.externalPort.map(String.init), status.publicAddress, status.publicHost,
         status.problem?.rawValue]
    }

    private static func explanation(_ status: RemoteAccessStatus) -> String {
        switch status.problem {
        case .noGateway: "this machine has no default gateway"
        case .noRouterSupport: "the router answers neither NAT-PMP nor UPnP"
        case .routerRefused: "the router refused to open the port"
        case .sharedAddress:
            "the router's internet address \(status.publicAddress ?? "") is not public (the operator's CGNAT or another router is "
                + "in front), so no port can be opened from here"
        case .portTaken: "the port is taken by another machine"
        case .duckDNSFailed: "the DuckDNS update failed"
        case nil: "no reason given"
        }
    }

    /// A setting without its spaces, nil when empty.
    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The router's WAN address when it has one: 0.0.0.0 and other special addresses mean it has none yet.
    private static func publicAddress(_ address: String) -> String? {
        guard let kind = NetworkInterfaces.kind(of: address), kind != .special else { return nil }
        return address
    }

    private static func isShared(_ address: String) -> Bool {
        let kind = NetworkInterfaces.kind(of: address)
        return kind == .private || kind == .shared
    }

    /// Half the lease, as RFC 6886 says, between a minute and half an hour. Permanent mappings are added again every
    /// half hour too: a router that restarted gets them back.
    static func renewal(after lease: Int) -> TimeInterval {
        lease <= 0 ? 1800 : min(1800, max(60, TimeInterval(lease) / 2))
    }

    /// RFC 6886's test: the router restarted when its epoch is more than 2 s behind the last one plus 7/8 of the time
    /// since it was read.
    static func routerRestarted(previous: UInt32, readAt: Date, epoch: UInt32, now: Date = Date()) -> Bool {
        Double(epoch) + 2 < Double(previous) + max(0, now.timeIntervalSince(readAt)) * 7 / 8
    }

    /// In a container on a bridge network, the gateway is the container's host, not the router.
    private static func containerHint(gateway: String, problem: RemoteAccessStatus.Problem) -> String? {
        let inContainer = FileManager.default.fileExists(atPath: "/.dockerenv") || FileManager.default.fileExists(atPath: "/run/.containerenv")
        guard problem == .noRouterSupport, inContainer, let bytes = NetworkInterfaces.ipv4Bytes(gateway), bytes[0] == 172,
              (16...31).contains(bytes[1]) else { return nil }
        return "the gateway \(gateway) is a container network's: give the server the host's network (network_mode: host)"
    }
}
