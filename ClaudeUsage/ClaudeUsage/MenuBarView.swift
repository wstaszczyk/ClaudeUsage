import SwiftUI

// MARK: - Design tokens  (pixel-matched to Token Usage States.html)

private enum DS {
    // Colours — adaptive: resolved dynamically per system appearance
    // bg/fg/muted/divider/hover use NSColor semantic values so the dropdown
    // respects the user's light or dark mode without a hard-coded override.
    static let bg        = Color(nsColor: .windowBackgroundColor)  // ~#1C1C1E dark, ~#ECECEC light
    static let fg        = Color(nsColor: .labelColor)             // ~#F5F5F7 dark, ~#1D1D1F light
    static let muted     = Color(nsColor: .secondaryLabelColor)    // ~#888 dark, ~#6E6E73 light
    static let divider   = Color(nsColor: .separatorColor)         // thin rule, adaptive
    static let hover     = Color(nsColor: .quaternaryLabelColor)   // very subtle tint, adaptive
    // Zone / action colours: explicit hex — sufficient contrast on both backgrounds
    static let red       = Color(hex: "FF453A")   // --system-red (Quit)
    static let green     = Color(hex: "34C759")   // --zone-clear (Apple system green)
    static let amber     = Color(hex: "F59E0B")   // --zone-wind
    static let zoneRed   = Color(hex: "EF4444")   // --zone-finish

    // Layout  (all from .dropdown / .dd-row CSS)
    static let cardWidth:   CGFloat = 320   // min-width: 320px
    static let cardPad:     CGFloat = 8     // padding: 8px 0 on .dropdown
    static let rowH:        CGFloat = 6     // .dd-row vertical padding
    static let rowHdense:   CGFloat = 4     // .dd-row.dense vertical padding
    static let rowX:        CGFloat = 14    // .dd-row horizontal padding
}

// MARK: - Root

struct MenuBarView: View {
    @Environment(UsageViewModel.self) private var vm
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch vm.state {
            case .idle, .loading:   loadingRows
            case .error(let msg):   errorRows(msg)
            case .loaded(let d, _, _): contentRows(d)
            }
        }
        // HTML: .dropdown { padding: 8px 0 }
        .padding(.vertical, DS.cardPad)
        .frame(width: DS.cardWidth)
        .background(DS.bg)
    }

    // MARK: Loading

    private var loadingRows: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(DS.muted)
            Text("Loading…").foregroundColor(DS.muted)
        }
        .font(.system(size: 13))
        .row()
    }

    // MARK: Error

    @ViewBuilder
    private func errorRows(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Unable to load usage", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.fg)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(DS.muted)
            Text("Make sure Claude Desktop is open.")
                .font(.system(size: 11))
                .foregroundColor(DS.muted)
        }
        .row()

        Hairline()
        ActionRow("Refresh", openURL: openURL) { Task { await vm.refresh() } }
        Hairline()
        ActionRow("Quit", isDestructive: true, openURL: openURL) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: Content  (flat structure mirrors HTML .dropdown children)

    @ViewBuilder
    private func contentRows(_ data: UsageData) -> some View {

        // ── 5-hour section ───────────────────────────────────────────────────
        // HTML: dd-row > dd-label
        Text("5-hour limit")
            .label()
            .row()

        if let p = data.fiveHour {
            let color = vm.zoneColor(for: p.utilization)

            // HTML: dd-row > dd-bar.{zone}   (block chars + %)
            BlockBar(pct: p.utilization, color: color)
                .row()

            // Approximate data note (shown when API is unavailable)
            if vm.state.isApproximate {
                if data.isBlockReset {
                    // Block reset detected in JSONL but live session data is unavailable.
                    // Active session tokens may not be in JSONL yet — show a clear prompt.
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text("Block reset · open Claude Desktop app to sync")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(DS.amber)
                    .row(v: 3)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10))
                        Text("Estimated · open Claude Desktop to sync")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(DS.muted)
                    .row(v: 3)
                }
            }

            // HTML: dd-row.dense > dd-reset
            // When block has reset and we're in fallback, hide the misleading countdown
            if !(vm.state.isApproximate && data.isBlockReset) {
                HStack(spacing: 0) {
                    Text("Resets at \(vm.resetTimeString(p.resetsAt))")
                        .foregroundColor(DS.fg)
                    Text("  ·  ").foregroundColor(DS.muted)
                    Text("\(vm.remainingString(p.resetsAt)) remaining")
                        .foregroundColor(DS.muted)
                }
                .font(.system(size: 13))
                .row(v: DS.rowHdense)
            }
        }

        // ── Divider ──────────────────────────────────────────────────────────
        Hairline()

        // ── Weekly section ───────────────────────────────────────────────────
        let seven    = data.sevenDay
        let omelette = data.sevenDayOmelette
        let resetsAt = seven?.resetsAt ?? omelette?.resetsAt ?? ""

        // HTML: dd-row > dd-label  (section header)
        HStack(spacing: 0) {
            Text("Weekly usage")
            if !resetsAt.isEmpty {
                Text("  ·  resets \(vm.weeklyResetString(resetsAt))")
            }
        }
        .label()
        .row()

        if let p = seven {
            weeklyRow(label: "All models", pct: p.utilization)
        } else if let tokens = data.sevenDayTokensApproximate, tokens > 0 {
            weeklyTokenRow(label: "All models", tokens: tokens)
        }
        if let p = omelette {
            weeklyRow(label: "Claude Design", pct: p.utilization)
        }

        // ── Divider ──────────────────────────────────────────────────────────
        Hairline()

        // ── Actions ──────────────────────────────────────────────────────────
        ActionRow("Refresh", openURL: openURL) { Task { await vm.refresh() } }
        LaunchAtLoginRow(isOn: vm.launchAtLogin) { vm.toggleLaunchAtLogin() }
        Hairline()
        ActionRow("Quit", isDestructive: true, openURL: openURL) {
            NSApplication.shared.terminate(nil)
        }
    }

    // HTML: dd-models row  (label + short bar, indented 4pt extra on left)
    private func weeklyRow(label: String, pct: Double) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundColor(DS.fg)
                .frame(width: 96, alignment: .leading)
            BlockBar(pct: pct, color: DS.green, height: 4)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.rowX + 4)   // 4pt extra indent vs standard row
        .padding(.vertical, DS.rowHdense)
    }

    // Fallback: raw token count when weekly % is unavailable (JSONL mode, no limit known)
    private func weeklyTokenRow(label: String, tokens: Int) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundColor(DS.fg)
                .frame(width: 96, alignment: .leading)
            Text("~\(formatTokens(tokens))")
                .foregroundColor(DS.muted)
                .font(.system(size: 13, design: .monospaced))
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.rowX + 4)
        .padding(.vertical, DS.rowHdense)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fK tok", Double(n) / 1_000) }
        return "\(n) tok"
    }
}

// MARK: - BlockBar
//
// Full-width bar: stretches from left margin to right margin.
// % label is pinned to the right at fixed width.
//
//  [━━━━━━━━━━━━━━━░░░░░░░░░░░░░░░░░░░░░]  68%
//   ↑ colored fill  ↑ dimmed track        ↑ fixed

private struct BlockBar: View {
    let pct:    Double
    let color:  Color
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(pct, 0), 100)

        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(clamped / 100))
                }
            }
            .frame(height: height)

            Text("\(Int(clamped.rounded()))%")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hairline divider
// HTML: .dd-divider { height:1px; margin:6px 0 }

private struct Hairline: View {
    var body: some View {
        DS.divider
            .frame(height: 1)
            .padding(.vertical, 6)
    }
}

// MARK: - Action row
// HTML: .dd-action { padding: 6px 14px }  +  hover: --card-hover

private struct ActionRow: View {
    let title:         String
    let isDestructive: Bool
    let openURL:       OpenURLAction
    let action:        () -> Void

    @State private var hovered = false

    init(
        _ title: String,
        isDestructive: Bool = false,
        openURL: OpenURLAction,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isDestructive = isDestructive
        self.openURL = openURL
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(isDestructive ? DS.red : DS.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.rowX)
                .padding(.vertical, DS.rowH)
                .background(hovered ? DS.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Launch at Login toggle row

private struct LaunchAtLoginRow: View {
    let isOn:   Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack {
            Text("Launch at Login")
                .font(.system(size: 13))
                .foregroundColor(DS.fg)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { _ in action() }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, DS.rowX)
        .padding(.vertical, DS.rowH)
        .background(hovered ? DS.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { action() }
    }
}

// MARK: - View modifiers

private extension View {
    /// Standard row padding — HTML .dd-row { padding: 6px 14px }
    /// frame(maxWidth: .infinity) makes every row span the full card width,
    /// matching the block-div behaviour of HTML .dd-row.
    func row(v: CGFloat = DS.rowH) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.rowX)
            .padding(.vertical, v)
    }

    /// Muted label style — HTML .dd-label { font-size:11px; color:#888 }
    func label() -> some View {
        self
            .font(.system(size: 11))
            .foregroundColor(DS.muted)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >>  8) & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}
