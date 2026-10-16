import SwiftUI
import LidlessCore

/// The studio door sign, and the panel's main control: press it to go on air, press it
/// again to go off air. Lit red while a session runs; dark glass with its lettering still
/// visible when off. Going on air strikes the lamp in two steps, like a studio lamp warming.
struct OnAirSign: View {
    let lit: Bool
    /// When the running session started; the lit sign counts time on air from it.
    var since: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SignFace(lit: lit, since: since)
        }
        .buttonStyle(SignButtonStyle())
        .keyboardShortcut(.return, modifiers: [])
        .help(lit ? String(localized: "Go off air") : String(localized: "Go on air"))
        .accessibilityLabel(lit ? Text("Go off air") : Text("Go on air"))
        .accessibilityValue(lit ? Text("On air: Lidless keeps the Mac awake") : Text("Off air"))
    }
}

/// Hover lifts the light a little, a press sinks the sign: it reads as something to press.
private struct SignButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0 : (hovering ? 0.07 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SignFace: View {
    let lit: Bool
    let since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var brightness: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Studio.offAirGlass)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Studio.onAirLit, Studio.onAir],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(brightness)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lit ? Studio.onAirRim : Color.black.opacity(0.6), lineWidth: 1)
            HStack(spacing: 14) {
                lettering
                if lit, let since {
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1, height: 26)
                        .transition(.opacity)
                    // Studio on-air clock: time since this session went on air.
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(StatusPresentation.formatElapsed(context.date.timeIntervalSince(since)))
                            .font(.system(size: 21, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .accessibilityLabel(Text("Time on air"))
                }
            }
            .padding(.horizontal, 12)
            .animation(.easeOut(duration: 0.25), value: lit)
        }
        .frame(height: 56)
        .onAppear { brightness = lit ? 1 : 0 }
        .onChange(of: lit) { _, isLit in strike(isLit) }
    }

    private var lettering: some View {
        let size: CGFloat = lit && since != nil ? 19 : 21
        return Text("ON AIR")
            .font(StudioFont.sign(size: size))
            .tracking(size * 0.15)
            .foregroundStyle(Studio.offAirLettering)
            .overlay(
                Text("ON AIR")
                    .font(StudioFont.sign(size: size))
                    .tracking(size * 0.15)
                    .foregroundStyle(.white)
                    .opacity(brightness)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func strike(_ isLit: Bool) {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { brightness = isLit ? 1 : 0 }
            return
        }
        if isLit {
            withAnimation(.easeOut(duration: 0.06)) { brightness = 0.55 }
            withAnimation(.easeIn(duration: 0.05).delay(0.07)) { brightness = 0.25 }
            withAnimation(.easeOut(duration: 0.12).delay(0.13)) { brightness = 1 }
        } else {
            withAnimation(.easeOut(duration: 0.35)) { brightness = 0 }
        }
    }
}
