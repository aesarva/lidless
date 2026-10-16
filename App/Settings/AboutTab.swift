import AppKit
import SwiftUI

struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lidless").font(.system(size: 22, weight: .semibold))
            Text("Version \(version)").foregroundStyle(.secondary).monospacedDigit()
            Link("github.com/alexsarva/lidless", destination: URL(string: "https://github.com/alexsarva/lidless")!)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}
