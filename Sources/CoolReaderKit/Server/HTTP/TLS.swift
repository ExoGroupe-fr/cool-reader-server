import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import X509

/// The server's own certificate, made at the first start and kept in the config folder. No certificate authority
/// vouches for it: Cool Reader pins its fingerprint, which an invitation carries or the first pairing records.
nonisolated struct ServerCertificate: Sendable {
    /// The certificate in DER, as a TLS client receives it.
    let der: [UInt8]
    let sslContext: NIOSSLContext

    /// SHA-256 of the certificate, in lowercase hex: what invitations carry and the app compares.
    var fingerprint: String { Self.fingerprint(of: der) }

    static func fingerprint(of der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The certificate in `directory`, made there first if it isn't.
    static func loadOrCreate(in directory: URL) throws -> ServerCertificate {
        let certificateFile = directory.appendingPathComponent("certificate.pem")
        let keyFile = directory.appendingPathComponent("private-key.pem")
        if !FileManager.default.fileExists(atPath: certificateFile.path) || !FileManager.default.fileExists(atPath: keyFile.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (certificate, key) = try make()
            try Data(key.utf8).write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            try Data(certificate.utf8).write(to: certificateFile, options: .atomic)
        }
        let certificatePEM = try String(contentsOf: certificateFile, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyFile, encoding: .utf8)
        let certificate = try NIOSSLCertificate(bytes: Array(certificatePEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)))
        configuration.minimumTLSVersion = .tlsv12
        return ServerCertificate(der: try certificate.toDERBytes(), sslContext: try NIOSSLContext(configuration: configuration))
    }

    /// A P-256 key and a certificate it signs itself, both in PEM. It lasts twenty years: nothing renews a pinned
    /// certificate, and changing it means pairing every device again.
    private static func make() throws -> (certificate: String, key: String) {
        let key = P256.Signing.PrivateKey()
        let signingKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("Cool Reader Server")
            OrganizationName("Cool Reader Server")
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: signingKey)
        return (try certificate.serializeAsPEM().pemString, key.pemRepresentation)
    }
}

/// What the handlers learn about a connection once it starts: whether it speaks TLS.
nonisolated final class ConnectionInfo: Sendable {
    private let secure = NIOLockedValueBox(false)

    var isSecure: Bool {
        get { secure.withLockedValue { $0 } }
        set { secure.withLockedValue { $0 = newValue } }
    }
}

/// HTTP and HTTPS on one port, as Plex does: a TLS connection opens with a handshake record (0x16), plain HTTP
/// with a method's letters. The first bytes decide, then this handler leaves the pipeline.
nonisolated final class ProtocolSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let sslContext: NIOSSLContext
    private let connection: ConnectionInfo

    init(sslContext: NIOSSLContext, connection: ConnectionInfo) {
        self.sslContext = sslContext
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0x16 {
            connection.isSecure = true
            do {
                try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext), position: .after(self))
            } catch {
                context.close(promise: nil)
                return
            }
        }
        context.fireChannelRead(data)
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}
