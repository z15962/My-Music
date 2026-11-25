import SwiftUI
import AVFoundation

let accentColor = Color(red: 1, green: 0.22, blue: 0.36)

@main struct MusicApp: App {
    @State private var store = Store()
    @State private var player = Player()
    @Environment(\.scenePhase) private var phase
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(player)
                .preferredColorScheme(.dark).tint(accentColor)
                .onChange(of: phase) { store.persist() }
        }
    }
}
