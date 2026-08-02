import SwiftUI

/// The one-time (and re-viewable) posture instructions. `isOnboarding`
/// controls copy only; `onContinue` dismisses / advances.
struct PostureGuideView: View {
    let isOnboarding: Bool
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Sit upright in a chair with your back straight. Hold the phone with the hand shown for each session. Keep your arm up. Don't rest it on a desk or table, and don't lean on anything.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    HStack(alignment: .top, spacing: 16) {
                        figurePanel(kind: .doSit, badge: "checkmark.seal.fill",
                                    tint: .green, label: "Do this",
                                    caption: "Back straight, phone up, arm free.")
                        figurePanel(kind: .dontSit, badge: "xmark.seal.fill",
                                    tint: .red, label: "Not this",
                                    caption: "Slouched, arm on the desk.")
                    }
                    .padding(.horizontal)

                    Button(action: onContinue) {
                        Text(isOnboarding ? "Got it, let's start" : "Done")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("How to sit")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func figurePanel(kind: PostureFigure.Kind, badge: String, tint: Color, label: String, caption: String) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PostureFigure(kind: kind)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                Image(systemName: badge)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .padding(8)
            }
            Text(label).font(.subheadline).bold().foregroundStyle(tint)
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
