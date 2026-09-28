import Foundation
import ServiceManagement
import Combine

/// Wraps `SMAppService.mainApp` (macOS 13+) so the app can register/
/// unregister itself as a login item. For today's usage totals to be
/// meaningful, the app needs to actually be running — this is what lets it
/// start automatically instead of relying on the user remembering to open
/// it every day.
///
/// Note: `SMAppService` only works when running from inside a proper `.app`
/// bundle (see Scripts/build_app.sh) — a bare `swift run` executable has no
/// bundle identity to register, so toggling this while running that way
/// will fail silently (status stays `.notRegistered`).
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
