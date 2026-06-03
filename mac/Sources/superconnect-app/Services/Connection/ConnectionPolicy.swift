import Foundation

/// A transport-independent identity for "which physical tablet is this?", derived purely from the
/// connect-time `Endpoint` (Tier-1, best-effort). It deliberately does NOT bridge the wired hdc serial
/// and a LAN host — they live in different namespaces — so the wired+wireless duplicate cannot be
/// recognized here; that gap is closed post-handshake by `peerId` (Tier-2, see `ConnectionCoordinator`).
/// Conservative by design: only an EXACT match means "same device", so two genuinely distinct tablets
/// (distinct LAN IPs / serials) are never merged. See docs/CONFLICTS.md.
enum PhysicalKey: Equatable {
    case serial(String)   // wired (hdc): the device serial
    case host(String)     // wireless: the normalized LAN host (port ignored — one host = one tablet)

    static func from(_ device: Device) -> PhysicalKey {
        switch device.endpoint {
        case .wiredHdc(let serial, _): return .serial(serial)
        case .wiredAdb(let serial, _): return .serial("adb:" + serial)   // namespaced: never collide with an hdc serial
        case .tcp(let host, _):        return .host(normalizeHost(host))
        }
    }

    /// Strip an IPv6 zone (`%en0`) and lowercase so the same host compares equal across sources.
    /// Does NOT bridge IPv4↔IPv6: a BLE-advertised IPv4 and an mDNS-resolved IPv6 for one tablet stay
    /// distinct here and fall through to the tablet guard / peerId reconcile (documented in CONFLICTS.md).
    private static func normalizeHost(_ host: String) -> String {
        var s = host.lowercased()
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s
    }
}

/// The outcome of an admission decision.
enum Admission: Equatable {
    case allow
    case refuse(AppError)
}

/// The ONE module permitted to know both the candidate device and the set of live links, so the
/// cross-device conflict predicate lives in a single injected, unit-testable seam — never scattered
/// across the coordinator, the four discovery sources, and the UI (which would break each module's
/// isolation contract; see docs/CONFLICTS.md). `ConnectionCoordinator` *asks and obeys*; it does not
/// own the rule. Injected from `AppEnvironment`, exactly like `tunnelFor`/`engineFor`.
protocol ConnectionPolicy {
    /// May `device` connect, given the currently-live links? SOFT by design: refuse only when the
    /// candidate is PROVABLY the same physical tablet as a live link (an exact Tier-1 `PhysicalKey`
    /// match). On any ambiguity it returns `.allow`, so one Mac → many DIFFERENT tablets always works.
    /// (One accepted residual: the wireless key is host-*without*-port, so two genuinely distinct
    /// tablets reached at the SAME host — exotic NAT/port-forward — collapse to one key. Distinct LAN
    /// tablets have distinct IPs, so this never bites the supported topology. See docs/CONFLICTS.md.)
    func admit(_ device: Device, against live: [LiveLinkInfo]) -> Admission
}

/// Default policy: connect-time Tier-1 de-dup. Catches the common "same tablet shown as several
/// wireless cards" case (mDNS + BLE + manual all resolving to one LAN host, or two manual entries to
/// the same IP) before a tunnel/virtual-display is wasted. The wired+wireless case and the N-distinct-
/// Macs case are handled authoritatively by the tablet's single-active guard (and the Mac peerId
/// reconcile), not here.
struct DefaultConnectionPolicy: ConnectionPolicy {
    func admit(_ device: Device, against live: [LiveLinkInfo]) -> Admission {
        let key = PhysicalKey.from(device)
        for link in live where link.deviceID != device.id {
            if link.physicalKey == key { return .refuse(.alreadyConnectedElsewhere) }
        }
        return .allow
    }
}
