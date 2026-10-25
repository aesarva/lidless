import AppKit
import SwiftUI

struct AboutTab: View {
    let updates: any UpdateSource

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lidless").font(.system(size: 22, weight: .semibold))
            Text("Version \(updates.currentVersion) (build \(updates.currentBuild))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Link("github.com/aesarva/lidless", destination: URL(string: "https://github.com/aesarva/lidless")!)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}
