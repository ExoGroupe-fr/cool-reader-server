import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import CoolReaderKit

/// NAT-PMP and UPnP messages, addresses and DuckDNS URLs, then remote access end to end against a fake router
/// (NAT-PMP, SSDP, description and SOAP) and a fake DuckDNS on 127.0.0.1. Nothing goes to the real router.
struct RemoteAccessTests {
    @Test func buildsNATPMPRequests() {
        #expect(NATPMP.externalAddressRequest == [0, 0])
        #expect(NATPMP.mappingRequest(internalPort: 7272, externalPort: 8080, lifetime: 3600)
            == [0, 2, 0, 0, 0x1C, 0x68, 0x1F, 0x90, 0, 0, 0x0E, 0x10])
        // Removal: external port and lifetime 0.
        #expect(NATPMP.mappingRequest(internalPort: 7272, externalPort: 0, lifetime: 0) == [0, 2, 0, 0, 0x1C, 0x68, 0, 0, 0, 0, 0, 0])
    }

    @Test func readsNATPMPAnswers() throws {
        let address = try NATPMP.parseExternalAddress([0, 128, 0, 0, 0, 0, 0x01, 0x2C, 203, 0, 113, 7])
        #expect(address == NATPMP.ExternalAddress(address: "203.0.113.7", epoch: 300))
        let mapping = try NATPMP.parseMapping([0, 130, 0, 0, 0, 0, 0x01, 0x2C, 0x1C, 0x68, 0x1C, 0x69, 0, 0, 0x07, 0x08])
        #expect(mapping == NATPMP.Mapping(internalPort: 7272, externalPort: 7273, lifetime: 1800, epoch: 300))
        #expect(throws: NATPMP.Failure.refused(code: 2)) {
            try NATPMP.parseMapping([0, 130, 0, 2, 0, 0, 0, 1, 0x1C, 0x68, 0, 0, 0, 0, 0, 0])
        }
        #expect(throws: NATPMP.Failure.unsupported) { try NATPMP.parseExternalAddress([0, 128, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: NATPMP.Failure.unsupported) { try NATPMP.parseExternalAddress([2, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: NATPMP.Failure.malformed) { try NATPMP.parseExternalAddress([0, 128, 0, 0, 0, 0]) }
        #expect(throws: NATPMP.Failure.malformed) { try NATPMP.parseMapping([0, 129, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
    }

    /// A gateway without NAT-PMP refuses the datagram: no need to wait for the whole backoff.
    @Test func givesUpOnAGatewayWithoutNATPMP() async throws {
        let port = try await Self.closedUDPPort()
        let started = Date()
        await #expect(throws: NATPMP.Failure.noAnswer) {
            try await NATPMP.externalAddress(gateway: "127.0.0.1", port: port)
        }
        #expect(Date().timeIntervalSince(started) < 3.5)
    }

    @Test func readsSSDPAnswers() {
        let answer = "HTTP/1.1 200 OK\r\nCache-Control: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
            + "USN: uuid:00000000-0000-0000-0000-000000000000::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nEXT:\r\n"
            + "Server: Router UPnP/1.1 MiniUPnPd/2.3\r\nlocation: http://10.0.0.1:5000/rootDesc.xml\r\n\r\n"
        #expect(UPnP.location(fromSearchResponse: answer) == URL(string: "http://10.0.0.1:5000/rootDesc.xml"))
        #expect(UPnP.location(fromSearchResponse: answer.replacingOccurrences(of: "200 OK", with: "404 Not Found")) == nil)
        #expect(UPnP.location(fromSearchResponse: answer.replacingOccurrences(of: "location: http", with: "location: ftp")) == nil)
        // A media server that answers every search is not a gateway.
        let mediaServer = answer.replacingOccurrences(of: "device:InternetGatewayDevice:1\r\nUSN", with: "device:MediaServer:1\r\nUSN")
        #expect(UPnP.location(fromSearchResponse: mediaServer) == nil)
        let search = String(decoding: UPnP.searchMessage(target: UPnP.searchTargets[0], host: "239.255.255.250:1900"), as: UTF8.self)
        #expect(search == "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n")
    }

    /// The WAN connections deep in the devices, WANIPConnection first, relative control URLs resolved against the
    /// description's URL (no URLBase) or against URLBase, and nothing on another host.
    @Test func findsTheControlURLInNestedDevices() throws {
        let location = try #require(URL(string: "http://10.0.0.1:5000/desc/rootDesc.xml"))
        let services = UPnP.connectionServices(description: Data(Self.deviceDescription(urlBase: nil).utf8), location: location)
        #expect(services.map(\.type) == ["urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"])
        #expect(services.map(\.controlURL.absoluteString) == ["http://10.0.0.1:5000/desc/ctl/IPConn", "http://10.0.0.1:5000/ctl/PPPConn"])

        let based = UPnP.connectionServices(description: Data(Self.deviceDescription(urlBase: "http://10.0.0.1:5000").utf8), location: location)
        #expect(based.first?.controlURL.absoluteString == "http://10.0.0.1:5000/ctl/IPConn")

        let elsewhere = Self.deviceDescription(urlBase: nil).replacingOccurrences(of: "<controlURL>ctl/IPConn", with: "<controlURL>http://203.0.113.50/ctl/IPConn")
        #expect(UPnP.connectionServices(description: Data(elsewhere.utf8), location: location).map(\.controlURL.absoluteString)
            == ["http://10.0.0.1:5000/ctl/PPPConn"])
    }

    @Test func buildsSOAPEnvelopes() throws {
        let envelope = UPnP.soapEnvelope(action: "AddPortMapping", service: "urn:schemas-upnp-org:service:WANIPConnection:1", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", "7272"), ("NewProtocol", "TCP"), ("NewPortMappingDescription", "Books & <Comics>"),
        ])
        #expect(envelope.hasPrefix("<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""))
        let body: String = "<s:Body><u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"
            + "<NewRemoteHost></NewRemoteHost><NewExternalPort>7272</NewExternalPort><NewProtocol>TCP</NewProtocol>"
            + "<NewPortMappingDescription>Books &amp; &lt;Comics&gt;</NewPortMappingDescription></u:AddPortMapping></s:Body>"
        #expect(envelope.contains(body))
        let parsed = try #require(MiniXML.parse(Data(envelope.utf8)))
        #expect(parsed.descendants("NewPortMappingDescription").first?.trimmedText == "Books & <Comics>")
    }

    @Test func readsSOAPAnswersAndFaults() {
        let conflict = Data(Self.soapFault(718, "ConflictInMappingEntry").utf8)
        #expect(UPnP.fault(in: conflict) == .fault(code: 718, description: "ConflictInMappingEntry"))
        #expect(UPnP.fault(in: Data(Self.soapFault(725, "OnlyPermanentLeasesSupported").utf8))
            == .fault(code: 725, description: "OnlyPermanentLeasesSupported"))
        let answer = Data(Self.soapAnswer("GetExternalIPAddress", [("NewExternalIPAddress", "203.0.113.9")]).utf8)
        #expect(UPnP.fault(in: answer) == nil)
        #expect(UPnP.values(in: answer, action: "GetExternalIPAddress") == ["NewExternalIPAddress": "203.0.113.9"])
        #expect(UPnP.values(in: conflict, action: "AddPortMapping") == nil)
    }

    @Test func classifiesRouterAddresses() {
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.20.30"] { #expect(NetworkInterfaces.kind(of: address) == .private) }
        for address in ["100.64.0.1", "100.127.255.255", "192.0.0.2"] { #expect(NetworkInterfaces.kind(of: address) == .shared) }
        for address in ["0.0.0.0", "127.0.0.1", "169.254.10.20", "239.255.255.250"] { #expect(NetworkInterfaces.kind(of: address) == .special) }
        for address in ["203.0.113.7", "100.63.255.255", "100.128.0.1", "172.32.0.1", "8.8.8.8"] {
            #expect(NetworkInterfaces.kind(of: address) == .public)
        }
        for text in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "+1.2.3.4", "a.b.c.d", "::1", "router.local"] {
            #expect(NetworkInterfaces.kind(of: text) == nil)
        }
    }

    @Test func buildsDuckDNSUpdates() throws {
        let url = try #require(DuckDNS.requestURL(domain: "MyLibrary.duckdns.org", token: " 00000000-0000-4000-8000-000000000000 "))
        #expect(url.absoluteString == "https://www.duckdns.org/update?domains=mylibrary&token=00000000-0000-4000-8000-000000000000&ip=")
        for domain in ["mylibrary", "https://mylibrary.duckdns.org/", "www.mylibrary.duckdns.org."] {
            #expect(DuckDNS.host(domain) == "mylibrary.duckdns.org")
        }
        #expect(DuckDNS.subdomain("my library") == nil)
        #expect(DuckDNS.subdomain("") == nil)
    }

    @Test func formatsEndpoints() {
        #expect(RemoteAccess.endpoint("books.example.org", port: 7272) == "books.example.org:7272")
        #expect(RemoteAccess.endpoint(" https://books.example.org/opds ", port: 7272) == "books.example.org:7272")
        #expect(RemoteAccess.endpoint("books.example.org:8443", port: 7272) == "books.example.org:8443")
        #expect(RemoteAccess.endpoint("2001:db8::1", port: 7272) == "[2001:db8::1]:7272")
        #expect(RemoteAccess.endpoint("[2001:db8::1]:8443", port: 7272) == "[2001:db8::1]:8443")
    }

    @Test func schedulesRenewals() {
        #expect(RemoteAccess.renewal(after: 3600) == 1800)
        #expect(RemoteAccess.renewal(after: 7200) == 1800)
        #expect(RemoteAccess.renewal(after: 30) == 60)
        #expect(RemoteAccess.renewal(after: 0) == 1800)
        let read = Date(timeIntervalSince1970: 1_000_000)
        #expect(!RemoteAccess.routerRestarted(previous: 5000, readAt: read, epoch: 5300, now: read.addingTimeInterval(300)))
        #expect(RemoteAccess.routerRestarted(previous: 5000, readAt: read, epoch: 290, now: read.addingTimeInterval(300)))
    }

    @Test func readsTheLinuxRouteTable() {
        let table = """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
            docker0\t00000000\t010011AC\t0003\t0\t0\t0\t00000000\t0\t0\t0
            wlan0\t00000000\t0101000A\t0003\t0\t0\t600\t00000000\t0\t0\t0
            eth0\t00000000\t0102000A\t0003\t0\t0\t100\t00000000\t0\t0\t0
            eth0\t0002000A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0
            """
        #expect(NetworkInterfaces.gateway(fromRouteTable: table) == "10.0.2.1")
        #expect(NetworkInterfaces.gateway(fromRouteTable: "Iface\tDestination\tGateway\n") == nil)
    }

    #if canImport(Darwin)
    /// Routing messages as sysctl(NET_RT_FLAGS) returns them: a network route, a default route scoped to another
    /// interface, then the primary default route.
    @Test func readsTheDefaultRouteFromRoutingMessages() {
        func sockaddr(_ address: [UInt8]) -> [UInt8] { [16, UInt8(AF_INET), 0, 0] + address + [UInt8](repeating: 0, count: 8) }
        func message(destination: [UInt8], gateway: [UInt8], flags: Int32) -> [UInt8] {
            var header = rt_msghdr()
            header.rtm_version = UInt8(RTM_VERSION)
            header.rtm_type = UInt8(RTM_GET)
            header.rtm_flags = flags
            header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK
            // The netmask of a default route comes empty: four bytes of padding.
            let addresses = sockaddr(destination) + sockaddr(gateway) + [0, 0, 0, 0]
            header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + addresses.count)
            return withUnsafeBytes(of: header) { Array($0) } + addresses
        }
        let up = RTF_UP | RTF_GATEWAY
        let messages = message(destination: [10, 8, 0, 0], gateway: [10, 0, 0, 254], flags: up)
            + message(destination: [0, 0, 0, 0], gateway: [10, 0, 1, 1], flags: up | RTF_IFSCOPE)
            + message(destination: [0, 0, 0, 0], gateway: [10, 0, 0, 1], flags: up)
        #expect(NetworkInterfaces.gateway(fromRoutingMessages: messages) == "10.0.0.1")
        #expect(NetworkInterfaces.gateway(fromRoutingMessages: Array(messages.prefix(2 * MemoryLayout<rt_msghdr>.size + 72))) == "10.0.1.1")
    }
    #endif

    /// What this machine reports about itself: whatever the network, no loopback and well-formed addresses.
    @Test func listsThisMachinesAddresses() {
        let addresses = NetworkInterfaces.localAddresses()
        #expect(!addresses.contains("127.0.0.1"))
        #expect(addresses.allSatisfy { NetworkInterfaces.ipv4Bytes($0) != nil && !$0.hasPrefix("169.254.") })
        if let gateway = NetworkInterfaces.defaultGateway() { #expect(NetworkInterfaces.ipv4Bytes(gateway) != nil) }
        #expect(NetworkInterfaces.localAddress(toward: "127.0.0.1") == "127.0.0.1")
    }

    /// NAT-PMP opens the port, gives another one than asked, and the mapping goes when remote access is turned off.
    @Test func opensAndClosesThePortWithNATPMP() async throws {
        let router = try await Self.natPMPRouter(address: "203.0.113.7")
        defer { router.stop() }
        let access = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true, externalPort: 8080),
                                  environment: Self.environment(natPMP: router.port))
        await access.start()
        let status = await Self.settled(access)
        #expect(status.state == .open)
        #expect(status.method == "NAT-PMP")
        #expect(status.externalPort == 8081)
        #expect(status.publicAddress == "203.0.113.7")
        #expect(status.gateway == "127.0.0.1")
        #expect(status.localAddress == "127.0.0.1")
        #expect(status.problem == nil)
        #expect(await access.publicEndpoints == ["203.0.113.7:8081"])
        #expect(router.distinctRequests == [[0, 0], NATPMP.mappingRequest(internalPort: 7272, externalPort: 8080, lifetime: 3600)])

        // Turned off, with a host the user forwards to by hand.
        await access.update(RemoteAccessSettings(isEnabled: false, publicHost: "books.example.org"))
        #expect(await access.status.state == .manual)
        #expect(await access.publicEndpoints == ["books.example.org:7272"])
        await access.stop()
        #expect(router.requests.values.last == NATPMP.mappingRequest(internalPort: 7272, externalPort: 0, lifetime: 0))
        #expect(await access.status.state == .off)
        #expect(await access.publicEndpoints.isEmpty)
    }

    /// A router that only speaks UPnP and only keeps permanent mappings (725).
    @Test func opensThePortWithUPnPWhenNATPMPIsMissing() async throws {
        let natPMP = try await Self.unsupportedNATPMP()
        let gateway = try await FakeGateway.start(externalAddress: "203.0.113.9", addFaults: [725])
        defer {
            natPMP.stop()
            gateway.stop()
        }
        let access = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true), description: "Cool Reader Server",
                                  environment: Self.environment(natPMP: natPMP.port, ssdp: gateway.ssdp.port))
        await access.start()
        let status = await Self.settled(access)
        #expect(status.state == .open)
        #expect(status.method == "UPnP")
        #expect(status.externalPort == 7272)
        #expect(status.publicAddress == "203.0.113.9")
        #expect(await access.publicEndpoints == ["203.0.113.9:7272"])
        #expect(gateway.actions == ["GetExternalIPAddress", "AddPortMapping", "AddPortMapping"])
        let adds = gateway.http.calls.values.filter { $0.action == "AddPortMapping" }
        let arguments: String = "<NewExternalPort>7272</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>7272</NewInternalPort>"
            + "<NewInternalClient>127.0.0.1</NewInternalClient><NewEnabled>1</NewEnabled>"
            + "<NewPortMappingDescription>Cool Reader Server</NewPortMappingDescription><NewLeaseDuration>3600</NewLeaseDuration>"
        #expect(adds.first?.body.contains(arguments) == true)
        #expect(adds.last?.body.contains("<NewLeaseDuration>0</NewLeaseDuration>") == true)
        #expect(adds.first?.soapAction == "\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"")
        #expect(gateway.http.calls.values.first?.path == "/rootDesc.xml")

        await access.stop()
        #expect(gateway.actions.suffix(2) == ["GetSpecificPortMappingEntry", "DeletePortMapping"])
        #expect(await access.status.state == .off)
    }

    /// 718: the port is mapped already. This machine's own mapping (left by a previous run) is fine; another
    /// machine's is reported, with who has it.
    @Test func tellsItsOwnMappingFromAnotherMachines() async throws {
        let natPMP = try await Self.unsupportedNATPMP()
        let ours = try await FakeGateway.start(externalAddress: "203.0.113.9", addFaults: [718], entry: (client: "127.0.0.1", port: 7272))
        let theirs = try await FakeGateway.start(externalAddress: "203.0.113.9", addFaults: [718], entry: (client: "10.0.0.20", port: 32400))
        defer {
            natPMP.stop()
            ours.stop()
            theirs.stop()
        }
        let first = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true),
                                 environment: Self.environment(natPMP: natPMP.port, ssdp: ours.ssdp.port))
        await first.start()
        #expect(await Self.settled(first).state == .open)
        await first.stop()

        let second = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true),
                                  environment: Self.environment(natPMP: natPMP.port, ssdp: theirs.ssdp.port))
        await second.start()
        let status = await Self.settled(second)
        #expect(status.state == .failed)
        #expect(status.problem == .portTaken)
        #expect(status.detail == "port 7272 is forwarded to 10.0.0.20:32400, Media server")
        #expect(await second.publicEndpoints.isEmpty)
        await second.stop()
        #expect(!theirs.actions.contains("DeletePortMapping"))
    }

    /// The router's own address is the operator's (CGNAT): no port can be opened from here, so none is asked for.
    @Test func saysWhenTheRouterIsBehindAnotherNAT() async throws {
        let router = try await Self.natPMPRouter(address: "100.64.12.34")
        defer { router.stop() }
        let access = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true),
                                  environment: Self.environment(natPMP: router.port))
        await access.start()
        let status = await Self.settled(access)
        #expect(status.state == .failed)
        #expect(status.problem == .sharedAddress)
        #expect(status.method == "NAT-PMP")
        #expect(status.publicAddress == "100.64.12.34")
        #expect(await access.publicEndpoints.isEmpty)
        #expect(router.distinctRequests == [[0, 0]])
        await access.stop()
    }

    @Test func reportsNoGatewayAndNoRouter() async throws {
        let lost = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true),
                                environment: RemoteAccess.Environment(gateway: { nil }))
        await lost.start()
        #expect(await Self.settled(lost).problem == .noGateway)
        await lost.stop()

        let closed = try await Self.closedUDPPort()
        let silent = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true),
                                  environment: Self.environment(natPMP: closed, ssdp: closed))
        await silent.start()
        let status = await Self.settled(silent)
        #expect(status.state == .failed)
        #expect(status.problem == .noRouterSupport)
        await silent.stop()
    }

    /// The name is updated with the caller's address (empty ip), listed first once DuckDNS took it, and a refusal
    /// shows without the token.
    @Test func keepsTheDuckDNSNameUpToDate() async throws {
        let router = try await Self.natPMPRouter(address: "203.0.113.7")
        let duckDNS = try await FakeHTTPServer.start { (call: FakeHTTPServer.Call, _: [FakeHTTPServer.Call]) -> (HTTPResponseStatus, String) in
            (.ok, call.path.contains("token=right-token") ? "OK" : "KO")
        }
        defer {
            router.stop()
            duckDNS.stop()
        }
        let updateURL = try #require(URL(string: "http://127.0.0.1:\(duckDNS.port)/update"))
        let access = RemoteAccess(localPort: 7272, settings: RemoteAccessSettings(isEnabled: true, duckDNSDomain: "MyLibrary.duckdns.org",
                                                                                   duckDNSToken: "right-token"),
                                  environment: Self.environment(natPMP: router.port, duckDNS: updateURL))
        await access.start()
        let status = await Self.settled(access)
        #expect(status.state == .open)
        #expect(status.publicHost == "mylibrary.duckdns.org")
        #expect(status.problem == nil)
        #expect(await access.publicEndpoints == ["mylibrary.duckdns.org:7273", "203.0.113.7:7273"])
        #expect(duckDNS.calls.values.map(\.path) == ["/update?domains=mylibrary&token=right-token&ip="])

        await access.update(RemoteAccessSettings(isEnabled: true, duckDNSDomain: "mylibrary", duckDNSToken: "wrong-token"))
        let refused = await Self.settled(access)
        #expect(refused.state == .open)
        #expect(refused.problem == .duckDNSFailed)
        #expect(refused.publicHost == nil)
        #expect(refused.detail?.contains("token") == true)
        #expect(refused.detail?.contains("wrong-token") == false)
        #expect(await access.publicEndpoints == ["203.0.113.7:7273"])
        await access.stop()
    }

    @Test func decodesOlderSettings() throws {
        let settings = try JSONDecoder().decode(RemoteAccessSettings.self, from: Data(#"{"publicHost": "books.example.org"}"#.utf8))
        #expect(settings == RemoteAccessSettings(publicHost: "books.example.org"))
        let saved = try JSONEncoder().encode(RemoteAccessSettings(isEnabled: true, externalPort: 8443))
        #expect(try JSONDecoder().decode(RemoteAccessSettings.self, from: saved) == RemoteAccessSettings(isEnabled: true, externalPort: 8443))
    }

    static func environment(natPMP: Int, ssdp: Int = 9, duckDNS: URL = URL(string: "http://127.0.0.1:9/update")!) -> RemoteAccess.Environment {
        RemoteAccess.Environment(gateway: { "127.0.0.1" }, natPMPPort: natPMP, ssdpAddress: "127.0.0.1", ssdpPort: ssdp, duckDNSURL: duckDNS)
    }

    /// The status once the work after `start` or `update` is done.
    static func settled(_ access: RemoteAccess) async -> RemoteAccessStatus {
        for _ in 0..<500 {
            let status = await access.status
            if status.state != .working { return status }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await access.status
    }

    /// A NAT-PMP router with this WAN address. It gives the port after the one asked for, like a router whose port
    /// is taken.
    static func natPMPRouter(address: String) async throws -> FakeUDPServer {
        let wan = NetworkInterfaces.ipv4Bytes(address) ?? [0, 0, 0, 0]
        return try await FakeUDPServer.start { (request: [UInt8]) -> [UInt8]? in
            let epoch: [UInt8] = [0, 0, 0x01, 0x2C]
            if request == [0, 0] { return [0, 128, 0, 0] + epoch + wan }
            guard request.count == 12, request[0] == 0, request[1] == 2 else { return nil }
            let asked = Int(request[6]) << 8 | Int(request[7])
            let removing = request[8...11].allSatisfy { $0 == 0 }
            let given = removing ? 0 : asked + 1
            return [0, 130, 0, 0] + epoch + Array(request[4...5]) + [UInt8(given >> 8), UInt8(given & 0xFF)] + Array(request[8...11])
        }
    }

    /// A gateway that only speaks PCP: NAT-PMP's "unsupported version".
    static func unsupportedNATPMP() async throws -> FakeUDPServer {
        try await FakeUDPServer.start { (request: [UInt8]) -> [UInt8]? in
            request.count >= 2 ? [0, request[1] | 0x80, 0, 1] + [UInt8](repeating: 0, count: 8) : nil
        }
    }

    /// A UDP port where nothing listens.
    static func closedUDPPort() async throws -> Int {
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 9
        try await channel.close().get()
        return port
    }

    static func deviceDescription(urlBase: String?) -> String {
        """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          \(urlBase.map { "<URLBase>\($0)</URLBase>" } ?? "")
          <device>
            <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
            <serviceList>
              <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/ctl/L3F</controlURL></service>
            </serviceList>
            <deviceList>
              <device>
                <deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
                <serviceList>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
                    <controlURL>/ctl/CmnIfCfg</controlURL>
                  </service>
                </serviceList>
                <deviceList>
                  <device>
                    <deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
                    <serviceList>
                      <service>
                        <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
                        <serviceId>urn:upnp-org:serviceId:WANPPPConn1</serviceId>
                        <controlURL>/ctl/PPPConn</controlURL>
                      </service>
                      <service>
                        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                        <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
                        <controlURL>ctl/IPConn</controlURL>
                      </service>
                    </serviceList>
                  </device>
                </deviceList>
              </device>
            </deviceList>
          </device>
        </root>
        """
    }

    static func soapAnswer(_ action: String, _ values: [(String, String)] = []) -> String {
        let fields = values.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">\(fields)</u:\(action)Response>"
            + "</s:Body></s:Envelope>\r\n"
    }

    static func soapFault(_ code: Int, _ description: String) -> String {
        """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode>\
        <errorDescription>\(description)</errorDescription></UPnPError></detail>
        </s:Fault></s:Body></s:Envelope>
        """
    }

    /// Values seen by a fake server, from its event loop.
    final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A UDP server on 127.0.0.1 that answers each datagram with `reply`'s bytes, if any.
    final class FakeUDPServer: Sendable {
        let port: Int
        let requests: Recorder<[UInt8]>
        private let channel: any Channel
        private let task: Task<Void, Never>

        private init(port: Int, requests: Recorder<[UInt8]>, channel: any Channel, task: Task<Void, Never>) {
            self.port = port
            self.requests = requests
            self.channel = channel
            self.task = task
        }

        static func start(reply: @escaping @Sendable ([UInt8]) -> [UInt8]?) async throws -> FakeUDPServer {
            let requests = Recorder<[UInt8]>()
            let server = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .bind(host: "127.0.0.1", port: 0) { (channel: any Channel) -> EventLoopFuture<NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>> in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
                    }
                }
            let task = Task<Void, Never> {
                _ = try? await server.executeThenClose { inbound, outbound in
                    for try await envelope in inbound {
                        let request = Array(envelope.data.readableBytesView)
                        requests.append(request)
                        if let answer = reply(request) {
                            try await outbound.write(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: ByteBuffer(bytes: answer)))
                        }
                    }
                }
            }
            return FakeUDPServer(port: server.channel.localAddress?.port ?? 0, requests: requests, channel: server.channel, task: task)
        }

        /// The requests without the repeats of a client that resent before the answer came.
        var distinctRequests: [[UInt8]] {
            requests.values.reduce(into: [[UInt8]]()) { (result: inout [[UInt8]], request: [UInt8]) in
                if result.last != request { result.append(request) }
            }
        }

        func stop() {
            task.cancel()
            channel.close(promise: nil)
        }
    }

    /// An HTTP server on 127.0.0.1: `respond` gets each request and the ones before, and returns the status and body.
    final class FakeHTTPServer: Sendable {
        struct Call: Sendable {
            var method: String
            var path: String
            var soapAction: String?
            var body: String

            /// "AddPortMapping" from "urn:…:WANIPConnection:1#AddPortMapping".
            var action: String? {
                soapAction.flatMap { $0.split(separator: "#").last }.map { String($0.filter { $0 != "\"" }) }
            }
        }

        let port: Int
        let calls: Recorder<Call>
        private let channel: any Channel
        private let task: Task<Void, Never>

        private init(port: Int, calls: Recorder<Call>, channel: any Channel, task: Task<Void, Never>) {
            self.port = port
            self.calls = calls
            self.channel = channel
            self.task = task
        }

        static func start(_ respond: @escaping @Sendable (Call, [Call]) -> (HTTPResponseStatus, String)) async throws -> FakeHTTPServer {
            let calls = Recorder<Call>()
            let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0) { (channel: any Channel) -> EventLoopFuture<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>> in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
                    }
                }
            let task = Task<Void, Never> {
                _ = try? await withThrowingDiscardingTaskGroup { group in
                    try await server.executeThenClose { inbound in
                        for try await connection in inbound {
                            group.addTask { await serve(connection, calls: calls, respond: respond) }
                        }
                    }
                }
            }
            return FakeHTTPServer(port: server.channel.localAddress?.port ?? 0, calls: calls, channel: server.channel, task: task)
        }

        func stop() {
            task.cancel()
            channel.close(promise: nil)
        }

        private static func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, calls: Recorder<Call>,
                                  respond: @Sendable (Call, [Call]) -> (HTTPResponseStatus, String)) async {
            try? await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead):
                        head = requestHead
                        body.clear()
                    case .body(var chunk):
                        body.writeBuffer(&chunk)
                    case .end:
                        guard let requestHead = head else { continue }
                        let call = Call(method: requestHead.method.rawValue, path: requestHead.uri,
                                        soapAction: requestHead.headers.first(name: "SOAPAction"), body: String(buffer: body))
                        calls.append(call)
                        let (status, text) = respond(call, calls.values)
                        let headers: HTTPHeaders = ["Content-Type": "text/xml; charset=\"utf-8\"", "Content-Length": String(text.utf8.count)]
                        try await outbound.write(.head(HTTPResponseHead(version: requestHead.version, status: status, headers: headers)))
                        try await outbound.write(.body(.byteBuffer(ByteBuffer(string: text))))
                        try await outbound.write(.end(nil))
                        head = nil
                    }
                }
            }
        }
    }

    /// A UPnP gateway: SSDP answers on a UDP port, the description and the SOAP control on an HTTP port.
    /// `addFaults` answer the AddPortMapping calls in turn; `entry` is the mapping already there, for 718.
    final class FakeGateway: Sendable {
        let ssdp: FakeUDPServer
        let http: FakeHTTPServer

        private init(ssdp: FakeUDPServer, http: FakeHTTPServer) {
            self.ssdp = ssdp
            self.http = http
        }

        /// The SOAP actions received, in order.
        var actions: [String] { http.calls.values.compactMap(\.action) }

        static func start(externalAddress: String, addFaults: [Int] = [], entry: (client: String, port: Int)? = nil) async throws -> FakeGateway {
            let description = RemoteAccessTests.deviceDescription(urlBase: nil)
            let http = try await FakeHTTPServer.start { (call: FakeHTTPServer.Call, history: [FakeHTTPServer.Call]) -> (HTTPResponseStatus, String) in
                if call.method == "GET" { return call.path == "/rootDesc.xml" ? (.ok, description) : (.notFound, "") }
                switch call.action {
                case "GetExternalIPAddress":
                    return (.ok, RemoteAccessTests.soapAnswer("GetExternalIPAddress", [("NewExternalIPAddress", externalAddress)]))
                case "AddPortMapping":
                    let attempt = history.filter { $0.action == "AddPortMapping" }.count - 1
                    if attempt < addFaults.count { return (.internalServerError, RemoteAccessTests.soapFault(addFaults[attempt], "Refused")) }
                    return (.ok, RemoteAccessTests.soapAnswer("AddPortMapping"))
                case "GetSpecificPortMappingEntry":
                    guard let entry else { return (.internalServerError, RemoteAccessTests.soapFault(714, "NoSuchEntryInArray")) }
                    return (.ok, RemoteAccessTests.soapAnswer("GetSpecificPortMappingEntry", [
                        ("NewInternalPort", String(entry.port)), ("NewInternalClient", entry.client), ("NewEnabled", "1"),
                        ("NewPortMappingDescription", entry.client == "127.0.0.1" ? "Cool Reader Server" : "Media server"),
                        ("NewLeaseDuration", "1200"),
                    ]))
                case "DeletePortMapping":
                    return (.ok, RemoteAccessTests.soapAnswer("DeletePortMapping"))
                default:
                    return (.internalServerError, RemoteAccessTests.soapFault(401, "Invalid Action"))
                }
            }
            let location = "http://127.0.0.1:\(http.port)/rootDesc.xml"
            let ssdp = try await FakeUDPServer.start { (request: [UInt8]) -> [UInt8]? in
                let text = String(decoding: request, as: UTF8.self)
                guard text.hasPrefix("M-SEARCH"), let target = text.split(separator: "\r\n").first(where: { $0.hasPrefix("ST: ") })?.dropFirst(4) else {
                    return nil
                }
                return Array(("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: \(target)\r\nUSN: uuid:fake::\(target)\r\nEXT:\r\n"
                    + "SERVER: Fake/1.0 UPnP/1.1 FakeGateway/1.0\r\nLOCATION: \(location)\r\n\r\n").utf8)
            }
            return FakeGateway(ssdp: ssdp, http: http)
        }

        func stop() {
            ssdp.stop()
            http.stop()
        }
    }
}
