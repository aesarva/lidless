import AppKit
import SwiftUI

struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lidless").font(.title)
            Text("Version \(version)").foregroundStyle(.secondary)
            Link("github.com/alexsarva/lidless", destination: URL(string: "https://github.com/alexsarva/lidless")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
