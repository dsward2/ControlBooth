import Foundation
import Observation
import dnssd

/// Finds Macs on the local network that accept Remote Apple Events (they
/// advertise `_eppc._tcp` once System Settings › General › Sharing › Remote
/// Application Scripting is on), for AntennaHead Radio's music source picker.
/// Each is resolved to its host name, which is what an `eppc://` URL needs.
@MainActor
@Observable
final class RemoteMacBrowser {
    struct Mac: Identifiable, Hashable {
        /// The Bonjour name, normally the Mac's computer name.
        let name: String
        /// "Studio-Mac.local"
        let host: String
        var id: String { name }
    }

    private(set) var macs: [Mac] = []
    private(set) var isBrowsing = false

    @ObservationIgnored private var browseRef: DNSServiceRef?
    @ObservationIgnored private var resolveRefs: [String: DNSServiceRef] = [:]

    func start() {
        guard browseRef == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceBrowse(&ref, 0, 0, "_eppc._tcp", "local.", Self.browseReply, context)
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, .main)
        browseRef = ref
        isBrowsing = true
    }

    func stop() {
        if let browseRef { DNSServiceRefDeallocate(browseRef) }
        browseRef = nil
        resolveRefs.values.forEach { DNSServiceRefDeallocate($0) }
        resolveRefs.removeAll()
        isBrowsing = false
    }

    private static let localHostName: String = {
        ProcessInfo.processInfo.hostName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }()

    fileprivate func found(name: String, regtype: String, domain: String, interface: UInt32, added: Bool) {
        guard added else {
            macs.removeAll { $0.name == name }
            return
        }
        guard resolveRefs[name] == nil else { return }
        // The resolve reply only has the escaped full name; carry the plain
        // one in the context (released when the reply arrives or on stop).
        let pending = PendingResolve(name: name, browser: self)
        let context = Unmanaged.passRetained(pending).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(&ref, 0, interface, name, regtype, domain, Self.resolveReply, context)
        guard error == kDNSServiceErr_NoError, let ref else {
            Unmanaged<PendingResolve>.fromOpaque(context).release()
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        resolveRefs[name] = ref
    }

    fileprivate func resolved(name: String, host: String) {
        if let ref = resolveRefs.removeValue(forKey: name) { DNSServiceRefDeallocate(ref) }
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard cleanHost.lowercased() != Self.localHostName else { return }   // this Mac
        macs.removeAll { $0.name == name }
        macs.append(Mac(name: name, host: cleanHost))
        macs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    fileprivate final class PendingResolve {
        let name: String
        weak var browser: RemoteMacBrowser?
        init(name: String, browser: RemoteMacBrowser) {
            self.name = name
            self.browser = browser
        }
    }

    private static let browseReply: DNSServiceBrowseReply = { _, flags, interface, error, name, regtype, domain, context in
        guard error == kDNSServiceErr_NoError, let context, let name, let regtype, let domain else { return }
        let browser = Unmanaged<RemoteMacBrowser>.fromOpaque(context).takeUnretainedValue()
        let added = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
        let n = String(cString: name), r = String(cString: regtype), d = String(cString: domain)
        MainActor.assumeIsolated {
            browser.found(name: n, regtype: r, domain: d, interface: interface, added: added)
        }
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, _, _, _, context in
        guard let context else { return }
        let pending = Unmanaged<PendingResolve>.fromOpaque(context).takeRetainedValue()
        guard error == kDNSServiceErr_NoError, let host else { return }
        let h = String(cString: host)
        MainActor.assumeIsolated {
            pending.browser?.resolved(name: pending.name, host: h)
        }
    }
}
