import AppKit
import CoreText
import SwiftUI

/// The "On Air" studio world: a black studio panel, a cream meter plate, and signal red
/// reserved for being on air (the lit sign, the session switch, the live zone of a meter).
enum Studio {
    static let panel = Color(hex: 0x121212)
    static let raised = Color(hex: 0x1C1C1C)
    static let hairline = Color(hex: 0xE8E2D6, opacity: 0.12)
    static let ink = Color(hex: 0xE8E2D6)
    static let inkDim = Color(hex: 0xE8E2D6, opacity: 0.66)
    static let inkFaint = Color(hex: 0xE8E2D6, opacity: 0.42)

    static let onAir = Color(hex: 0xE0342A)
    static let onAirLit = Color(hex: 0xEC4A3E)
    static let onAirRim = Color(hex: 0xA8221A)
    static let offAirGlass = Color(hex: 0x2A1311)
    static let offAirLettering = Color(hex: 0x6B2E28)

    static let plate = Color(hex: 0xE8E2D6)
    static let plateInk = Color(hex: 0x1A1A1A)
    static let plateInkDim = Color(hex: 0x1A1A1A, opacity: 0.62)
    static let plateSegmentOff = Color(hex: 0x1A1A1A, opacity: 0.13)

    /// Caution text on the black panel (paused lid mode, a blocked start).
    static let caution = Color(hex: 0xF2A65A)

    static let panelWidth: CGFloat = 320
    static let corner: CGFloat = 14
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Unbounded (SIL OFL, bundled) is the sign's lettering only; everything else is SF Pro.
@MainActor enum StudioFont {
    private static var registered = false

    static func register() {
        guard !registered,
              let url = Bundle.main.url(forResource: "Unbounded", withExtension: "ttf") else { return }
        registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    nonisolated static func sign(size: CGFloat) -> Font {
        .custom("Unbounded", size: size).weight(.bold)
    }
}
