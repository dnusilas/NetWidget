import WidgetKit
import SwiftUI
import AppIntents

struct NetEntry: TimelineEntry {
    let date: Date
    let snapshot: NetSnapshot
    let copied: String?
}

struct Provider: TimelineProvider {
    private static let copiedDuration: TimeInterval = 2

    func placeholder(in context: Context) -> NetEntry {
        NetEntry(date: Date(), snapshot: .placeholder, copied: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NetEntry) -> Void) {
        completion(NetEntry(date: Date(), snapshot: context.isPreview ? .placeholder : current(), copied: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetEntry>) -> Void) {
        Task {
            var snapshot = current()
            if snapshot.publicIP == nil {
                snapshot.publicIP = await NetworkReader.fetchPublicIP()
            }
            let now = Date()
            var entries: [NetEntry] = []
            if let copied = SharedStore.copied, now.timeIntervalSince(copied.at) < Self.copiedDuration {
                entries.append(NetEntry(date: now, snapshot: snapshot, copied: copied.ip))
                entries.append(NetEntry(date: copied.at.addingTimeInterval(Self.copiedDuration),
                                        snapshot: snapshot, copied: nil))
            } else {
                entries.append(NetEntry(date: now, snapshot: snapshot, copied: nil))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }

    private func current() -> NetSnapshot {
        let local = NetworkReader.interfaces()
        guard let shared = SharedStore.load() else {
            return NetSnapshot(interfaces: local, publicIP: nil, updatedAt: Date())
        }
        let localKnowsPrimary = local.contains(where: \.isPrimary)
        let merged = local.map { iface -> NetInterface in
            var iface = iface
            let match = shared.interfaces.first { $0.bsdName == iface.bsdName }
            iface.ssid = iface.ssid ?? match?.ssid
            if !localKnowsPrimary { iface.isPrimary = match?.isPrimary ?? false }
            return iface
        }
        return NetSnapshot(interfaces: NetworkReader.sorted(merged), publicIP: shared.publicIP, updatedAt: Date())
    }
}

extension NetSnapshot {
    static let placeholder = NetSnapshot(
        interfaces: [
            NetInterface(bsdName: "en0", displayName: "Wi-Fi", ip: "192.168.1.24",
                         ssid: "Home", isPrimary: true, kind: .wifi),
            NetInterface(bsdName: "utun4", displayName: "VPN", ip: "10.8.0.2",
                         ssid: nil, isPrimary: false, kind: .vpn),
        ],
        publicIP: "203.0.113.10",
        updatedAt: Date()
    )
}

// MARK: - Views

struct CopyRow: View {
    let symbol: String
    let title: String
    let ip: String
    let highlight: Bool
    let copied: Bool

    var body: some View {
        Button(intent: CopyIPIntent(ip: ip)) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlight ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(ip)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .opacity(copied ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetEntry

    private var interfaces: [NetInterface] {
        Array(entry.snapshot.interfaces.prefix(family == .systemSmall ? 1 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 6) {
            HStack {
                Text("Network").font(.system(size: 12, weight: .bold))
                Spacer()
                if entry.copied != nil {
                    Text("Copied").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                }
            }

            if interfaces.isEmpty {
                Label("Not connected", systemImage: "wifi.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(interfaces) { iface in
                CopyRow(symbol: iface.symbol, title: iface.title, ip: iface.ip,
                        highlight: iface.isPrimary, copied: entry.copied == iface.ip)
            }

            Spacer(minLength: 0)

            if let pub = entry.snapshot.publicIP {
                CopyRow(symbol: "globe", title: "Public IP", ip: pub,
                        highlight: false, copied: entry.copied == pub)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct NetWidgetExtension: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetWidget", provider: Provider()) { entry in
            NetWidgetView(entry: entry)
        }
        .configurationDisplayName("Network")
        .description("Connected networks and IP addresses. Click an IP to copy it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
