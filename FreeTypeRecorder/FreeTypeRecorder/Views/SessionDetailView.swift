import SwiftUI
import AVKit

struct SessionDetailView: View {
    let session: RecordingSession

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Screen Recording").font(.headline)
                    if session.hasScreenRecording {
                        VideoPlayer(player: AVPlayer(url: session.screenURL))
                            .frame(height: 300)
                    } else {
                        Text("No screen recording for this session — the screen broadcast wasn't started.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                VStack(alignment: .leading) {
                    Text("Privacy Silhouette Recording").font(.headline)
                    VideoPlayer(player: AVPlayer(url: session.faceURL))
                        .frame(height: 300)
                }
            }
            .padding()
        }
        .navigationTitle(session.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}
