import SwiftUI

// MARK: - PostureSelectView
//
// D2a — the "first page: L, R, Mid" of the opt-in "Posture training run"
// sub-flow (reachable from ParticipantSetupView, NOT folded into the default
// timed study — see the D2 spec's research-integrity requirement).
//
// A screen with three large buttons (Left / Right / Both). Pattern copied
// from HandCaptureView.swift: button styling, ring colors (ringColor(for:)
// blue/green/orange), Form/VStack layout.
//
// "Mid" == the existing HoldingHand.both case (no new enum case — see the
// spec's resolved OPEN QUESTION 2).
//
// On tap, the selected HoldingHand is written to SessionManager
// (selectedPosture) and onSelect fires so the caller can start the posture
// training session. This view does not itself start a session — it is a
// pure selection screen.

struct PostureSelectView: View {
    var onSelect: (HoldingHand) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose how you'll hold the phone for this typing session. Every keystroke and photo/motion sample captured during the next session will be labeled with this posture.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("Posture") {
                    postureButton(.left, systemImage: "hand.point.left.fill")
                    postureButton(.right, systemImage: "hand.point.right.fill")
                    postureButton(.both, systemImage: "hands.clap.fill", label: "Mid (Both hands)")
                }

                Section {
                    Button(action: onCancel) {
                        HStack {
                            Spacer()
                            Text("Cancel")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(.systemGray6))
                }
            }
            .navigationTitle("Posture Training Run")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func postureButton(_ hand: HoldingHand, systemImage: String, label: String? = nil) -> some View {
        Button(action: { onSelect(hand) }) {
            HStack {
                Label(label ?? hand.displayName, systemImage: systemImage)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.vertical, 10)
        }
        .listRowBackground(ringColor(for: hand))
    }

    // MARK: - Ring color helper
    //
    // Copied from HandCaptureView.ringColor(for:) — distinct color per
    // holding-hand condition so the active posture is visually obvious.
    // Left = blue, right = green, both = orange (app accent).
    private func ringColor(for hand: HoldingHand) -> Color {
        switch hand {
        case .left:    return .blue
        case .right:   return .green
        case .both:    return .orange
        case .unknown: return .orange
        }
    }
}
