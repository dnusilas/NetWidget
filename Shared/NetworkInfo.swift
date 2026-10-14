import Foundation
import SystemConfiguration

struct NetInterface: Codable, Hashable, Identifiable {
    var id: String { bsdName + ip }
    let bsdName: String
    let displayName: String
    let ip: String
    var ssid: String?
    var isPrimary: Bool
    let kind: Kind

    enum Kind: String, Codable { case wifi, ethernet, vpn, other }

    var title: String { ssid ?? displayName }

    var symbol: String {
        switch kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .vpn: return "lock.shield"
        case .other: return "network"
        }
    }
}

struct NetSnapshot: Codable, Equatable {
    var interfaces: [NetInterface]
    var publicIP: String?
    var updatedAt: Date

    static let empty = NetSnapshot(interfaces: [], publicIP: nil, updatedAt: .distantPast)

    var primary: NetInterface? { interfaces.first(where: \.isPrimary) ?? interfaces.first }
}

enum NetworkReader {
    static func interfaces(ssid: String? = nil) -> [NetInterface] {
        let info = interfaceInfo()
        let primary = primaryInterface()

        var result: [NetInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }

            let bsd = String(cString: ifa.ifa_name)
            let kind: NetInterface.Kind
            if info[bsd]?.isWiFi == true { kind = .wifi }
            else if bsd.hasPrefix("utun") || bsd.hasPrefix("ppp") || bsd.hasPrefix("ipsec") { kind = .vpn }
            else if bsd.hasPrefix("en") { kind = .ethernet }
            else { kind = .other }

            let display: String
            switch kind {
            case .wifi: display = info[bsd]?.name ?? "Wi-Fi"
            case .vpn: display = "VPN"
            default: display = info[bsd]?.name ?? bsd
            }

            result.append(NetInterface(bsdName: bsd, displayName: display, ip: ip,
                                       ssid: kind == .wifi ? ssid : nil,
                                       isPrimary: bsd == primary, kind: kind))
        }
        return sorted(result)
    }

    static func sorted(_ list: [NetInterface]) -> [NetInterface] {
        list.sorted { ($0.isPrimary ? 0 : 1, $0.bsdName) < ($1.isPrimary ? 0 : 1, $1.bsdName) }
    }

    private static func interfaceInfo() -> [String: (name: String, isWiFi: Bool)] {
        var map: [String: (name: String, isWiFi: Bool)] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return map }
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            map[bsd] = (name, type == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        return map
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetWidget" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    static func fetchPublicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty
        else { return nil }
        return ip
    }
}

enum SharedStore {
    private static let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
    private static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
    private static let snapshotKey = "snapshot"
    private static let copiedKey = "copied"
    private static let copiedAtKey = "copiedAt"

    static func load() -> NetSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(NetSnapshot.self, from: data)
    }

    static func save(_ snapshot: NetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func setCopied(_ ip: String) {
        defaults.set(ip, forKey: copiedKey)
        defaults.set(Date(), forKey: copiedAtKey)
    }

    static var copied: (ip: String, at: Date)? {
        guard let ip = defaults.string(forKey: copiedKey),
              let at = defaults.object(forKey: copiedAtKey) as? Date else { return nil }
        return (ip, at)
    }
}
