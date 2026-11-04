import SwiftUI
import Network
import CoreWLAN
import CoreLocation
import WidgetKit
import ServiceManagement

@main
struct NetWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // No menu bar icon or window: the app only runs in the background to keep the widget up to date.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: NetworkMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NetworkMonitor()
    }

    // Opening the app again while it is running forces a refresh.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        monitor?.refresh(includePublic: true, force: true)
        return false
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
final class NetworkMonitor: NSObject, CLLocationManagerDelegate {
    private(set) var snapshot = SharedStore.load() ?? .empty

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
