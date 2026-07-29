import SwiftUI

/// Sits directly above the keyboard, showing the most recently typed
/// characters. Ordinary SwiftUI content — no UIKit window tricks needed
/// here (unlike TouchDotOverlayView), since ReplayKit already captures
/// normal app content fine; the point is substituting for the keyboard
/// graphic itself, which never appears in the recording (see
/// RecentKeysTracker for why).
struct RecentKeysStripView: View {
    var body: some View {
        HStack {
            Text(RecentKeysTracker.shared.recentText)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}
