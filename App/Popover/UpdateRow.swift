import AppKit
import SwiftUI
import LidlessCore

/// The update row, last in the switch-row block above the footer. Nothing shows while there is no
/// news: idle, or up to date (that one is for Settings only).
struct UpdateRow: View {
    let updates: any UpdateSource
    @Environment(\.openURL) private var openURL

    /// The same dot as on the menu-bar icon: the system accent, never studio red or amber.
    static let dot = Color(nsColor: .controlAccentColor)

    var body: some View {
        switch updates.state {
        case .idle, .upToDate:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Studio.hairline).frame(height: 1)
                row
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch updates.state {
        case .available(let version, let notesURL):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Circle().fill(Self.dot).frame(width: 6, height: 6).accessibilityHidden(true)
                    title(String(localized: "Version \(version) available"))
                    Spacer(minLength: 8)
                    if let notesURL {
                        NotesLink { openURL(notesURL) }
                    }
                }
                StudioButton(title: String(localized: "Install and Relaunch"), fullWidth: true) {
                    updates.install()
                }
            }
        case .downloading(let version, let progress):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title(String(localized: "Downloading \(version)"))
                    Spacer(minLength: 8)
                    if let progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Studio.inkDim)
                    }
                }
                DownloadBar(fraction: progress)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                title(String(localized: "Installing…"))
            }
        case .waitingForLid:
            title(String(localized: "Installs when you open the lid"))
        case .failed(let message):
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    title(String(localized: "Couldn't update"))
                    // Sparkle's own words; the full text is in the tooltip.
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Studio.inkDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(message)
                }
                Spacer(minLength: 8)
                StudioButton(title: String(localized: "Retry")) { updates.checkNow() }
                    .disabled(!updates.canCheckNow)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                title(String(localized: "Checking for updates…"), color: Studio.inkDim)
            }
        case .needsMove:
            title(String(localized: "Move Lidless to Applications to keep it updated"), color: Studio.inkDim)
        case .idle, .upToDate:
            EmptyView()
        }
    }

    /// Row-title type, wrapping inside the column instead of widening it.
    private func title(_ text: String, color: Color = Studio.ink) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "What's new": the release page, opened in the browser only on a click.
private struct NotesLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("What's new")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Studio.ink : Studio.inkDim)
                .underline(hovering)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isLink)
    }
}

/// A quiet studio button: raised ground, hairline rim, cream lettering. Never red: red means on air.
private struct StudioButton: View {
    let title: String
    var fullWidth = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? Studio.ink : Studio.inkFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 26)
                .background(shape.fill(hovering && isEnabled ? Studio.ink.opacity(0.08) : Studio.raised))
                .overlay(shape.strokeBorder(Studio.hairline, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Download progress as a thin cream bar on a hairline track; with no size known yet, a short
/// segment sweeps across (held still under Reduce Motion).
private struct DownloadBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Studio.hairline)
                if let fraction {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Studio.ink)
                        .frame(width: width * min(1, max(0, fraction)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else if reduceMotion {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Studio.inkDim)
                        .frame(width: width * 0.3)
                } else {
                    TimelineView(.animation) { context in
                        let period = 1.4
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Studio.inkDim)
                            .frame(width: width * 0.3)
                            .offset(x: (width * 1.3) * phase - width * 0.3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(height: 4)
        // The title and the percentage beside it already say it.
        .accessibilityHidden(true)
    }
}
