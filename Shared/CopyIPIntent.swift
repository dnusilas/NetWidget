import AppIntents
import AppKit
import WidgetKit

struct CopyIPIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy IP Address"
    static var isDiscoverable = false

    @Parameter(title: "IP Address")
    var ip: String

    init() {}
    init(ip: String) { self.ip = ip }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
        }
        SharedStore.setCopied(ip)
        return .result()
    }
}
