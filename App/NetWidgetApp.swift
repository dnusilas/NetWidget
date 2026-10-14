import SwiftUI
import Network
import CoreWLAN
import CoreLocation
import WidgetKit
import ServiceManagement

@main
struct NetWidgetApp: App {
    @StateObject private var monitor = NetworkMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.snapshot.interfaces.isEmpty ? "wifi.slash" : "network")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if monitor.snapshot.interfaces.isEmpty {
            Text("Not connected")
        }
        ForEach(monitor.snapshot.interfaces) { iface in
            Button("\(iface.isPrimary ? "● " : "")\(iface.title) — \(iface.ip)") { copy(iface.ip) }
        }
        if let pub = monitor.snapshot.publicIP {
            Divider()
            Button("Public IP — \(pub)") { copy(pub) }
        }
        Divider()
        Button("Refresh") { monitor.refresh(includePublic: true, force: true) }
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { _, enabled in
                LoginItem.set(enabled)
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        Divider()
        Button("Quit NetWidget") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum LoginItem {
    private static let didSetupKey = "didSetupLoginItem"

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NetWidget login item error: \(error)")
        }
    }

    static func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: didSetupKey) else { return }
        UserDefaults.standard.set(true, forKey: didSetupKey)
        set(true)
    }
}

@MainActor
final class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot = SharedStore.load() ?? .empty

    private let pathMonitor = NWPathMonitor()
    private let location = CLLocationManager()
    private var timers: [Timer] = []

    override init() {
        super.init()
        LoginItem.enableOnFirstLaunch()
        location.delegate = self
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self?.refresh(includePublic: true)
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        timers = [
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(includePublic: false) }
            },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(includePublic: true) }
            },
        ]
        refresh(includePublic: true, force: true)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh(includePublic: false) }
    }

    func refresh(includePublic: Bool, force: Bool = false) {
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        let interfaces = NetworkReader.interfaces(ssid: ssid)
        update(interfaces: interfaces, publicIP: snapshot.publicIP, force: force)
        guard includePublic else { return }
        Task {
            let pub = await NetworkReader.fetchPublicIP()
            update(interfaces: snapshot.interfaces, publicIP: pub, force: false)
        }
    }

    private func update(interfaces: [NetInterface], publicIP: String?, force: Bool) {
        let changed = interfaces != snapshot.interfaces || publicIP != snapshot.publicIP
        guard changed || force else { return }
        snapshot = NetSnapshot(interfaces: interfaces, publicIP: publicIP, updatedAt: Date())
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
