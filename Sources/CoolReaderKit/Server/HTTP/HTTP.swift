import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix

/// A request, read whole: bodies are small (forms, JSON), the files only go out.
nonisolated struct Request: Sendable {
    var method: HTTPMethod
    /// Percent-decoded, without the query.
    var path: String
    var query: [String: String]
    var headers: HTTPHeaders
    var body: Data
    var remoteAddress: String?
    /// Filled by the router from the route's `:name` segments.
    var parameters: [String: String] = [:]

    func header(_ name: String) -> String? { headers.first(name: name) }

    func parameter(_ name: String) -> Int? { parameters[name].flatMap { Int($0) } }

    var cookies: [String: String] {
        var cookies: [String: String] = [:]
        for header in headers[canonicalForm: "Cookie"] {
            for pair in header.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { cookies[parts[0]] = parts[1] }
            }
        }
        return cookies
    }

    /// An HTML form's fields.
    var form: [String: String] {
        Self.decodeQuery(String(decoding: body, as: UTF8.self))
    }

    /// Several values for one field (checkboxes).
    func formValues(_ name: String) -> [String] {
        String(decoding: body, as: UTF8.self).split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.decode(parts[0]) == name else { return nil }
            return Self.decode(parts[1])
        }
    }

    func json<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    /// French when the browser or the app asks for it first, else English.
    var language: String {
        let accept = (header("Accept-Language") ?? "").lowercased()
        return accept.hasPrefix("fr") ? "fr" : "en"
    }

    static func decodeQuery(_ query: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[decode(parts[0])] = parts.count == 2 ? decode(parts[1]) : ""
        }
        return fields
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }
}

nonisolated struct Response: Sendable {
    enum Body: Sendable {
        case data(Data)
        /// Part of a file, sent in chunks.
        case file(URL, offset: Int64, length: Int64)
    }

    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Body

    init(status: HTTPResponseStatus = .ok, headers: HTTPHeaders = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(status: HTTPResponseStatus = .ok, contentType: String, data: Data) {
        self.init(status: status, headers: ["Content-Type": contentType], body: .data(data))
    }

    static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Response(status: status, contentType: "application/json; charset=utf-8", data: data)
    }

    static func html(_ text: String, status: HTTPResponseStatus = .ok) -> Response {
        var response = Response(status: status, contentType: "text/html; charset=utf-8", data: Data(text.utf8))
        response.headers.add(name: "Content-Security-Policy", value: "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
        response.headers.add(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.add(name: "Referrer-Policy", value: "same-origin")
        return response
    }

    static func xml(_ text: String, contentType: String) -> Response {
        Response(contentType: contentType, data: Data(text.utf8))
    }

    static func image(_ data: Data, contentType: String) -> Response {
        var response = Response(contentType: contentType, data: data)
        response.headers.add(name: "Cache-Control", value: "private, max-age=86400")
        return response
    }

    static func redirect(_ location: String) -> Response {
        Response(status: .seeOther, headers: ["Location": location])
    }

    static func error(_ status: HTTPResponseStatus, _ message: String) -> Response {
        .json(["error": message], status: status)
    }

    static var notFound: Response { .error(.notFound, "Not found.") }

    /// A whole file, or the range the client asked for (downloads that resume).
    static func file(_ url: URL, contentType: String, fileName: String, request: Request) -> Response {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return .notFound
        }
        var headers: HTTPHeaders = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        let ascii = fileName.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)")
        if let range = request.header("Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2, let start = Int64(bounds[0]), start < size {
                let end = min(Int64(bounds[1]) ?? (size - 1), size - 1)
                headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(size)")
                return Response(status: .partialContent, headers: headers, body: .file(url, offset: start, length: end - start + 1))
            }
        }
        return Response(headers: headers, body: .file(url, offset: 0, length: size))
    }
}

/// Routes by method and path: "/api/v1/series/:id" puts the segment in `parameters["id"]`.
nonisolated struct Router: Sendable {
    typealias Handler = @Sendable (Request) async throws -> Response

    private struct Route: Sendable {
        var method: HTTPMethod
        var segments: [String]
        var handler: Handler
    }

    private var routes: [Route] = []

    mutating func add(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method, segments: pattern.split(separator: "/").map(String.init), handler: handler))
    }

    func handle(_ request: Request) async -> Response {
        let segments = request.path.split(separator: "/").map(String.init)
        var pathFound = false
        for route in routes where route.segments.count == segments.count {
            var parameters: [String: String] = [:]
            var matches = true
            for (pattern, segment) in zip(route.segments, segments) {
                if pattern.hasPrefix(":") {
                    parameters[String(pattern.dropFirst())] = segment
                } else if pattern != segment {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            pathFound = true
            guard route.method == request.method || (request.method == .HEAD && route.method == .GET) else { continue }
            var routed = request
            routed.parameters = parameters
            do {
                return try await route.handler(routed)
            } catch let error as HTTPError {
                return .error(error.status, error.message)
            } catch {
                return .error(.internalServerError, "Something went wrong on the server.")
            }
        }
        return pathFound ? .error(.methodNotAllowed, "Method not allowed.") : .notFound
    }
}

nonisolated struct HTTPError: Error {
    var status: HTTPResponseStatus
    var message: String

    static let unauthorized = HTTPError(status: .unauthorized, message: "Sign in first.")
    static let forbidden = HTTPError(status: .forbidden, message: "This account can't see that.")
    static let notFound = HTTPError(status: .notFound, message: "Not found.")

    static func badRequest(_ message: String) -> HTTPError { HTTPError(status: .badRequest, message: message) }
}

/// The HTTP/1.1 server, on SwiftNIO: one task per connection, requests answered in turn.
nonisolated enum HTTPServer {
    static let maximumBodySize = 4 << 20

    static func run(host: String, port: Int, handler: @escaping @Sendable (Request) async -> Response,
                    onListening: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
                }
            }
        onListening(server.channel.localAddress?.port ?? port)
        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { inbound in
                for try await connection in inbound {
                    group.addTask { await serve(connection, handler: handler) }
                }
            }
        }
    }

    private static func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
                              handler: @Sendable (Request) async -> Response) async {
        let remote = connection.channel.remoteAddress?.ipAddress
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                var tooLarge = false
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead):
                        head = requestHead
                        body.clear()
                        tooLarge = false
                    case .body(var chunk):
                        if body.readableBytes + chunk.readableBytes > maximumBodySize {
                            tooLarge = true
                        } else {
                            body.writeBuffer(&chunk)
                        }
                    case .end:
                        guard let requestHead = head else { continue }
                        let response: Response
                        if tooLarge {
                            response = .error(.payloadTooLarge, "Request too large.")
                        } else {
                            response = await handler(request(from: requestHead, body: body, remote: remote))
                        }
                        try await write(response, for: requestHead, to: outbound)
                        if !requestHead.isKeepAlive { return }
                        head = nil
                    }
                }
            }
        } catch {
            // A client that leaves mid-request or mid-download: nothing to do.
        }
    }

    private static func request(from head: HTTPRequestHead, body: ByteBuffer, remote: String?) -> Request {
        let parts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        let query = parts.count > 1 ? Request.decodeQuery(String(parts[1])) : [:]
        return Request(method: head.method, path: path, query: query, headers: head.headers, body: Data(buffer: body),
                       remoteAddress: remote)
    }

    private static func write(_ response: Response, for head: HTTPRequestHead,
                              to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        var headers = response.headers
        headers.replaceOrAdd(name: "Connection", value: head.isKeepAlive ? "keep-alive" : "close")
        let sendsBody = head.method != .HEAD
        switch response.body {
        case .data(let data):
            headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
            try await outbound.write(.head(HTTPResponseHead(version: head.version, status: response.status, headers: headers)))
            if sendsBody, !data.isEmpty { try await outbound.write(.body(.byteBuffer(ByteBuffer(data: data)))) }
        case .file(let url, let offset, let length):
            headers.replaceOrAdd(name: "Content-Length", value: String(length))
            try await outbound.write(.head(HTTPResponseHead(version: head.version, status: response.status, headers: headers)))
            if sendsBody {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                var remaining = length
                while remaining > 0 {
                    let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                    guard !chunk.isEmpty else { break }
                    try await outbound.write(.body(.byteBuffer(ByteBuffer(data: chunk))))
                    remaining -= Int64(chunk.count)
                }
            }
        }
        try await outbound.write(.end(nil))
    }
}
