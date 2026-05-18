import SwiftUI
import ServiceManagement

// MARK: - Load state

enum LoadState {
    case idle
    case loading
    case loaded(UsageData, fetchedAt: Date, isApproximate: Bool)
    case error(String)

    var usageData: UsageData? {
        if case .loaded(let d, _, _) = self { return d }
        return nil
    }

    var isApproximate: Bool {
        if case .loaded(_, _, let approx) = self { return approx }
        return false
    }
}

// MARK: - ViewModel

@Observable
final class UsageViewModel {

    var state: LoadState = .idle
    var launchAtLogin: Bool = false

    private let service = UsageService()
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 30

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task { await refresh() }
        scheduleTimer()
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            // Not critical — user can add via System Settings if needed
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Refresh

    func refresh() async {
        if case .idle = state { state = .loading }
        do {
            let (data, isApprox) = try await service.fetch()
            state = .loaded(data, fetchedAt: Date(), isApproximate: isApprox)
        } catch {
            let message = (error as? UsageServiceError)?.errorDescription
                ?? error.localizedDescription
            state = .error(message)
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    // MARK: - Menu bar title

    /// Colored dot emoji for the menu bar label.
    /// Emoji always render in full colour regardless of menu bar template mode.
    var statusDot: String {
        guard let pct = state.usageData?.fiveHour?.utilization else {
            return "⚫️"   // grey — loading / no data
        }
        switch pct {
        case 90...:   return "🔴"
        case 75..<90: return "🟡"
        default:      return "🟢"
        }
    }

    var menuBarTitle: String {
        guard let five = state.usageData?.fiveHour else {
            switch state {
            case .loading, .idle: return "…"
            case .error:          return "⚠"
            case .loaded:         return "?"
            }
        }
        // When the block has reset in fallback mode, show a sync prompt instead
        // of a percentage that may not reflect an active session's real usage.
        if state.isApproximate, state.usageData?.isBlockReset == true {
            return "↺ sync"
        }
        let pct    = five.utilization.rounded()
        let time   = resetTimeString(five.resetsAt)
        let prefix = state.isApproximate ? "~" : ""
        let str    = "\(prefix)\(Int(pct))% · \(time)"
        switch pct {
        case 90...:   return "⚠ \(str)"
        case 75..<90: return "◑ \(str)"
        default:      return str
        }
    }

    // MARK: - Formatting

    func resetTimeString(_ iso: String) -> String {
        guard let dt = parseDate(iso) else { return "--:--" }
        let c = Calendar.current.dateComponents([.hour, .minute], from: dt)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    func remainingString(_ iso: String) -> String {
        guard let dt = parseDate(iso) else { return "--" }
        let secs = Int(dt.timeIntervalSinceNow)
        guard secs > 0 else { return "now" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Within 24h → just the time.  Beyond 24h → "Mon 17:00".
    func weeklyResetString(_ iso: String) -> String {
        guard let dt = parseDate(iso) else { return "--" }
        let c    = Calendar.current.dateComponents([.hour, .minute], from: dt)
        let time = String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
        if dt.timeIntervalSinceNow <= 86_400 {
            return time
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return "\(fmt.string(from: dt)) \(time)"
    }

    func zoneColor(for pct: Double) -> Color {
        switch pct {
        case 90...: return Color(hex: "EF4444")
        case 75..<90: return Color(hex: "F59E0B")
        default:      return Color(hex: "34C759")
        }
    }

    // MARK: - Private helpers

    private func parseDate(_ iso: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: iso) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: iso)
    }
}
