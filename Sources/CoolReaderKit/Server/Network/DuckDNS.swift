import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DuckDNS: a free name (myname.duckdns.org) that follows the home's public address, which most providers change
/// from time to time. An update with an empty address lets DuckDNS take the one the request comes from.
nonisolated enum DuckDNS {
    static let updateURL = URL(string: "https://www.duckdns.org/update")!

    enum Failure: Error, Equatable {
        case invalidDomain
        /// DuckDNS answered KO: a wrong token, or a name that isn't this account's.
        case refused
        case noAnswer
    }

    /// "myname" from "myname", "MyName.duckdns.org" or "https://myname.duckdns.org/"; nil for what can't be one.
    static func subdomain(_ domain: String) -> String? {
        var name = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        name = String(name.prefix { $0 != "/" })
        if name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".duckdns.org") { name.removeLast(".duckdns.org".count) }
        // "www.myname.duckdns.org" updates "myname".
        name = name.split(separator: ".").last.map(String.init) ?? ""
        guard !name.isEmpty, name.utf8.count <= 63,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        return name
    }

    static func host(_ domain: String) -> String? {
        subdomain(domain).map { "\($0).duckdns.org" }
    }

    static func requestURL(domain: String, token: String, base: URL = updateURL) -> URL? {
        guard let name = subdomain(domain), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "domains", value: name),
            URLQueryItem(name: "token", value: token.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "ip", value: ""),
        ]
        return components.url
    }

    /// Points the name at the address this request comes from; nil when DuckDNS answered OK. The token is in the
    /// URL only: nothing here logs it or hands it back.
    static func update(domain: String, token: String, base: URL = updateURL) async -> Failure? {
        guard let url = requestURL(domain: domain, token: token, base: base) else { return .invalidDomain }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CoolReaderServer/0.1 (+https://github.com/ExoGroupe-fr/cool-reader-server)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .noAnswer }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("OK") ? nil : .refused
    }

    /// What went wrong, for the admin page.
    static func describe(_ failure: Failure) -> String {
        switch failure {
        case .invalidDomain: "the domain is not a DuckDNS name (letters, digits and hyphens, then .duckdns.org)"
        case .refused: "DuckDNS answered KO: check the domain and the token"
        case .noAnswer: "DuckDNS didn't answer"
        }
    }
}
