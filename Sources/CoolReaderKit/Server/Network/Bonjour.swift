import Dispatch
import Foundation
#if canImport(dnssd)
import dnssd
#endif

/// Advertises the server on the home network as a DNS-SD service, `_coolreader._tcp`, so Cool Reader finds it
/// without anyone typing an address. The TXT record carries `id`, the server's UUID, by which the app recognises a
/// server it paired with after its address changed; `v`, the server's version; and `api`. On the Mac, mDNSResponder
/// advertises it through dns_sd; on Linux (a NAS, Docker with host networking), `MDNSResponder` does. Keep it for as
/// long as the server runs: it stops advertising when it goes away.
nonisolated final class ServiceAdvertiser: Sendable {
    /// What Cool Reader browses for.
    static let serviceType = "_coolreader._tcp"

    /// The instance name, at most 63 bytes. If another server on the network has it, mDNS adds a number: "Name (2)".
    let name: String
    let port: Int
    let txt: [String: String]
    #if canImport(dnssd)
    private let registration: Registration
    #else
    private let responder: MDNSResponder
    #endif

    init(name: String, port: Int, txt: [String: String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instance = DNSMessage.Name.label(trimmed.isEmpty ? "Cool Reader Server" : trimmed)
        self.name = instance
        self.port = port
        self.txt = txt
        #if canImport(dnssd)
        registration = Registration(name: instance, port: UInt16(clamping: port), txt: DNSMessage.txtData(DNSMessage.txtStrings(txt)))
        #else
        responder = MDNSResponder(service: MDNSResponder.Service(instance: instance, type: Self.serviceType, host: MDNSResponder.hostLabel(),
                                                                 port: UInt16(clamping: port), txt: DNSMessage.txtStrings(txt)))
        #endif
    }

    deinit {
        stop()
    }

    /// Starts advertising. Throws when it can't (mDNSResponder refuses, port 5353 can't be opened): the server works
    /// without it, it's just found by its address.
    func start() throws {
        #if canImport(dnssd)
        try registration.start()
        #else
        do {
            try responder.start()
        } catch {
            throw Failure(description: "the mDNS responder can't start (\(error))")
        }
        #endif
    }

    /// Stops advertising; browsers drop the service at once: dns_sd deregisters it, the responder says goodbye.
    func stop() {
        #if canImport(dnssd)
        registration.stop()
        #else
        responder.stop()
        #endif
    }

    /// Why advertising couldn't start, in a sentence for the log.
    nonisolated struct Failure: Error, CustomStringConvertible {
        var description: String
    }
}

#if canImport(dnssd)
nonisolated extension ServiceAdvertiser {
    /// A dns_sd registration. Its callbacks come on `queue`, where dns_sd also wants the reference deallocated.
    private nonisolated final class Registration: @unchecked Sendable {
        let name: String
        let port: UInt16
        let txt: [UInt8]
        private let queue = DispatchQueue(label: "CoolReader.Bonjour")
        // Only touched on `queue`.
        private var reference: DNSServiceRef?
        private var isRunning = false

        init(name: String, port: UInt16, txt: [UInt8]) {
            self.name = name
            self.port = port
            self.txt = txt
        }

        func start() throws {
            try queue.sync {
                guard !isRunning else { return }
                try register()
                isRunning = true
            }
        }

        func stop() {
            queue.sync {
                isRunning = false
                if let reference { DNSServiceRefDeallocate(reference) }
                reference = nil
            }
        }

        private func register() throws {
            var reference: DNSServiceRef?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let error = txt.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> DNSServiceErrorType in
                DNSServiceRegister(&reference, 0, 0, name, ServiceAdvertiser.serviceType, nil, nil, port.bigEndian, UInt16(bytes.count),
                                   bytes.baseAddress, { _, _, error, name, _, _, context in
                    guard let context else { return }
                    Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue().registered(error: error, name: name.map { String(cString: $0) })
                }, context)
            }
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
                throw Failure(description: "mDNSResponder refused the registration (error \(error))")
            }
            DNSServiceSetDispatchQueue(reference, queue)
            self.reference = reference
        }

        /// dns_sd's word on the registration: the name it got (mDNSResponder adds " (2)" if another server has it), or
        /// an error, such as mDNSResponder restarting, after which the registration starts over.
        private func registered(error: DNSServiceErrorType, name: String?) {
            guard isRunning else { return }
            if error == DNSServiceErrorType(kDNSServiceErr_NoError) {
                Log.info("Bonjour: advertising « \(name ?? self.name) » (\(ServiceAdvertiser.serviceType)) on port \(port).")
                return
            }
            Log.warning("Bonjour: mDNSResponder dropped the service (error \(error)); it's registered again in 5 s.")
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.registerAgain() }
        }

        private func registerAgain() {
            guard isRunning, reference == nil else { return }
            do {
                try register()
            } catch {
                Log.warning("Bonjour: \(error); trying again in 30 s.")
                queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.registerAgain() }
            }
        }
    }
}
#endif
