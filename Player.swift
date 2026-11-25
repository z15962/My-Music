import SwiftUI
import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable final class Player {
    var queue: [Track] = [], index = 0, isPlaying = false, shuffle = false, elapsed = 0.0
    var store: Store?
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    private var original: [Track] = []
    private let ap = AVPlayer()
    private var played = 0.0, last = 0.0, counted = false

    init() {
        ap.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        // Écran de verrouillage / Centre de contrôle / écouteurs
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle(true) }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle(false) }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.prev() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            let p = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in self?.seek(p) }; return .success
        }
    }

    func play(_ tracks: [Track], start: Int = 0, shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        original = tracks; self.shuffle = shuffle
        queue = shuffle ? tracks.shuffled() : tracks
        index = shuffle ? 0 : start
        load()
    }
    private func load() {
        guard let t = current else { return }
        ap.replaceCurrentItem(with: AVPlayerItem(url: t.url))
        played = 0; last = 0; counted = false; elapsed = 0
        ap.play(); isPlaying = true; info()
    }
    private func tick(_ t: Double) {
        elapsed = t
        let d = t - last; last = t
        guard isPlaying, d > 0, d < 2, let cur = current else { return }
        store?.addListen(cur.id, d); played += d
        if !counted && played >= 30 {                       // écoutée après 30 s
            counted = true; store?.db.events.append(PlayEvent(track: cur.id, date: .now))
        }
    }
    func toggle(_ on: Bool? = nil) {
        let p = on ?? !isPlaying
        p ? ap.play() : ap.pause(); isPlaying = p; info()
    }
    func seek(_ s: Double) { ap.seek(to: CMTime(seconds: s, preferredTimescale: 600)); elapsed = s; last = s; info() }
    func next() { guard !queue.isEmpty else { return }; index = (index + 1) % queue.count; load() }
    func prev() {
        if elapsed > 3 { seek(0) } else if !queue.isEmpty { index = (index - 1 + queue.count) % queue.count; load() }
    }
    func toggleShuffle() {
        guard let cur = current else { return }
        shuffle.toggle()
        if shuffle { queue = [cur] + original.filter { $0.id != cur.id }.shuffled(); index = 0 }
        else { queue = original; index = original.firstIndex(of: cur) ?? 0 }
    }
    private func info() {
        guard let t = current else { return }
        var d: [String: Any] = [MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: t.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if let data = store?.db.artistPhotos[t.artist], let img = UIImage(data: data) {
            d[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = d
    }
}
