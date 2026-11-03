import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// UPnP Internet Gateway Device, the port mapping protocol most home routers speak: an SSDP search finds the
/// router, its XML description gives the WAN connection's control URL, and SOAP calls to it open and close ports.
nonisolated enum UPnP {
    static let ssdpAddress = "239.255.255.250"
    static let ssdpPort = 1900
    static let searchTargets = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    /// A WAN connection service and where its SOAP calls go.
    struct Service: Equatable, Sendable {
        var type: String
        var controlURL: URL
    }

    /// A WAN connection that answered, and the router's WAN address (nil while it has none).
    struct Connection: Equatable, Sendable {
        var service: Service
        var externalAddress: String?
    }

    struct Opened: Equatable, Sendable {
        var externalPort: Int
        /// Seconds; 0 for a permanent mapping.
        var lease: Int
    }

    enum Failure: Error, Equatable {
        /// No gateway device answered the search, or none described a WAN connection.
        case notFound
        /// The device stopped answering, or answered without a UPnP error.
        case noAnswer(String)
        /// A UPnP error: 606 not authorized, 718 conflict, 725 permanent leases only…
        case fault(code: Int, description: String)
        /// The port already goes to another machine: its address, port and description.
        case portTaken(String)
    }

    static func searchMessage(target: String, host: String) -> [UInt8] {
        Array("M-SEARCH * HTTP/1.1\r\nHOST: \(host)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n".utf8)
    }

    /// The LOCATION of an answer to the search, when the answer comes from a gateway device.
    static func location(fromSearchResponse text: String) -> URL? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let status = lines.first, status.hasPrefix("HTTP/1."), status.split(separator: " ").dropFirst().first == "200" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = headers["ST"] ?? ""
        guard ["InternetGatewayDevice:", "WANIPConnection:", "WANPPPConnection:"].contains(where: { target.contains($0) }),
              let location = headers["LOCATION"], let url = URL(string: location), url.scheme?.lowercased() == "http", url.host != nil else {
            return nil
        }
        return url
    }

    /// Searches for gateway devices and collects the LOCATIONs that answer within `timeout`. Answers are kept only
    /// when the LOCATION is on the device that sent them; the gateway's comes first and ends the wait. The search
    /// also goes straight to the gateway (UPnP 1.1's unicast search), for networks that filter multicast.
    static func search(gateway: String, address: String = ssdpAddress, port: Int = ssdpPort, timeout: TimeInterval = 2) -> [URL] {
        guard let socket = NetworkInterfaces.UDPSocket() else { return [] }
        var destinations = [address]
        if let first = NetworkInterfaces.ipv4Bytes(address)?.first, (224...239).contains(first) {
            if let local = NetworkInterfaces.localAddress(toward: gateway) { socket.setMulticastInterface(local) }
            destinations.append(gateway)
        }
        for target in searchTargets {
            for destination in destinations {
                _ = socket.send(searchMessage(target: target, host: "\(destination):\(port)"), to: destination, port: port)
            }
        }
        var found: [URL] = []
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            guard case .datagram(let bytes, let sender) = socket.receive(timeout: deadline.timeIntervalSinceNow) else { break }
            guard let url = location(fromSearchResponse: String(decoding: bytes, as: UTF8.self)), url.host == sender,
                  !found.contains(url) else { continue }
            if sender == gateway { return [url] + found }
            found.append(url)
        }
        return found
    }

    static func discover(gateway: String, address: String = ssdpAddress, port: Int = ssdpPort) async -> [URL] {
        await NetworkInterfaces.blocking { search(gateway: gateway, address: address, port: port) }
    }

    /// The WAN connection services of a device description, best first (WANIPConnection:2, :1, then
    /// WANPPPConnection), wherever they are in the nested devices. Control URLs are resolved against URLBase, or
    /// the description's own URL; one on another host than the description's is left out.
    static func connectionServices(description: Data, location: URL) -> [Service] {
        guard let root = MiniXML.parse(description) else { return [] }
        let declaredBase = root.child("URLBase")?.trimmedText ?? ""
        let base = declaredBase.isEmpty ? location : URL(string: declaredBase) ?? location
        var services: [(rank: Int, index: Int, service: Service)] = []
        for node in root.descendants("service") {
            guard let type = node.child("serviceType")?.trimmedText, let control = node.child("controlURL")?.trimmedText, !control.isEmpty,
                  let url = URL(string: control, relativeTo: base)?.absoluteURL, url.host == location.host else { continue }
            let rank: Int
            if type.contains(":service:WANIPConnection:2") {
                rank = 0
            } else if type.contains(":service:WANIPConnection:") {
                rank = 1
            } else if type.contains(":service:WANPPPConnection:") {
                rank = 2
            } else {
                continue
            }
            services.append((rank, services.count, Service(type: type, controlURL: url)))
        }
        return services.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.service)
    }

    /// The first WAN connection that answers, across the devices found: one that knows its WAN address is
    /// preferred (a DSL router may list a PPP connection that isn't the one in use).
    static func connection(locations: [URL]) async -> Result<Connection, Failure> {
        var fallback: Connection?
        var lastFailure = Failure.notFound
        for location in locations {
            var request = URLRequest(url: location, timeoutInterval: 4)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            for service in connectionServices(description: data, location: location) {
                switch await externalAddress(on: service) {
                case .success(let address?):
                    return .success(Connection(service: service, externalAddress: address))
                case .success(nil):
                    fallback = fallback ?? Connection(service: service, externalAddress: nil)
                case .failure(let failure):
                    lastFailure = failure
                }
            }
        }
        return fallback.map { .success($0) } ?? .failure(lastFailure)
    }

    /// The router's WAN address; nil while it has none (empty or 0.0.0.0).
    static func externalAddress(on service: Service) async -> Result<String?, Failure> {
        await call("GetExternalIPAddress", on: service).map { values in
            let address = values["NewExternalIPAddress"] ?? ""
            return NetworkInterfaces.ipv4Bytes(address) == nil || address == "0.0.0.0" ? nil : address
        }
    }

    /// Maps `externalPort` to `client`:`internalPort` for `lease` seconds. Routers that only keep permanent mappings
    /// (725) get a lease of 0, and those that need the same port inside and out (724) get the internal port. A
    /// mapping already there (718) is fine when it is this machine's, and `portTaken` when it is another's.
    static func addMapping(on service: Service, externalPort: Int, internalPort: Int, client: String, description: String,
                           lease: Int = 3600) async -> Result<Opened, Failure> {
        var externalPort = externalPort
        var lease = lease
        var retried: Set<Int> = []
        while true {
            let result = await call("AddPortMapping", on: service, arguments: [
                ("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "TCP"),
                ("NewInternalPort", String(internalPort)), ("NewInternalClient", client), ("NewEnabled", "1"),
                ("NewPortMappingDescription", description), ("NewLeaseDuration", String(lease)),
            ])
            switch result {
            case .success:
                return .success(Opened(externalPort: externalPort, lease: lease))
            case .failure(.fault(725, _)) where lease != 0 && retried.insert(725).inserted:
                lease = 0
            case .failure(.fault(724, _)) where externalPort != internalPort && retried.insert(724).inserted:
                externalPort = internalPort
            case .failure(.fault(718, let text)):
                guard case .success(let entry) = await mappingEntry(on: service, externalPort: externalPort) else {
                    return .failure(.fault(code: 718, description: text))
                }
                if entry["NewInternalClient"] == client, entry["NewInternalPort"] == String(internalPort) {
                    return .success(Opened(externalPort: externalPort, lease: Int(entry["NewLeaseDuration"] ?? "") ?? lease))
                }
                let owner = "\(entry["NewInternalClient"] ?? "?"):\(entry["NewInternalPort"] ?? "?")"
                let name = entry["NewPortMappingDescription"].flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
                return .failure(.portTaken(owner + name))
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    /// Removes the mapping of `externalPort` when it is still this machine's: another machine may have taken the
    /// port since this one's lease ended.
    static func deleteMapping(on service: Service, externalPort: Int, internalPort: Int, client: String) async {
        if case .success(let entry) = await mappingEntry(on: service, externalPort: externalPort),
           entry["NewInternalClient"] != client || entry["NewInternalPort"] != String(internalPort) {
            return
        }
        _ = await call("DeletePortMapping", on: service, arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "TCP"),
        ])
    }

    static func mappingEntry(on service: Service, externalPort: Int) async -> Result<[String: String], Failure> {
        await call("GetSpecificPortMappingEntry", on: service, arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "TCP"),
        ])
    }

    /// One SOAP call: its answer's values (`NewExternalIPAddress`…), or its UPnP error.
    static func call(_ action: String, on service: Service, arguments: [(name: String, value: String)] = []) async -> Result<[String: String], Failure> {
        var request = URLRequest(url: service.controlURL, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(soapEnvelope(action: action, service: service.type, arguments: arguments).utf8)
        guard let (data, response) = try? await session.data(for: request) else {
            return .failure(.noAnswer("no answer to \(action)"))
        }
        if let fault = fault(in: data) { return .failure(fault) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return .failure(.noAnswer("HTTP \(status) to \(action)")) }
        return .success(values(in: data, action: action) ?? [:])
    }

    static func soapEnvelope(action: String, service: String, arguments: [(name: String, value: String)]) -> String {
        let fields = arguments.map { "<\($0.name)>\(escaped($0.value))</\($0.name)>" }.joined()
        return "<?xml version=\"1.0\"?>\r\n"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service)\">\(fields)</u:\(action)></s:Body></s:Envelope>\r\n"
    }

    /// The UPnP error in a SOAP fault, nil when there is no fault.
    static func fault(in data: Data) -> Failure? {
        guard let root = MiniXML.parse(data), let fault = root.descendants("Fault").first else { return nil }
        let code = fault.descendants("errorCode").first.flatMap { Int($0.trimmedText) } ?? 0
        let description = fault.descendants("errorDescription").first?.trimmedText ?? fault.descendants("faultstring").first?.trimmedText ?? ""
        return .fault(code: code, description: description)
    }

    /// The out arguments of an `<action>Response`.
    static func values(in data: Data, action: String) -> [String: String]? {
        guard let response = MiniXML.parse(data)?.descendants(action + "Response").first else { return nil }
        var values: [String: String] = [:]
        for child in response.children { values[child.name] = child.trimmedText }
        return values
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// The router is on the LAN: no proxy, no cache, short timeouts.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
