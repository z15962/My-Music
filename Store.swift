import SwiftUI
import AVFoundation
import Observation

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var file: String, title: String, artist: String, duration: Double
    var listened: Double = 0                       // temps d'écoute cumulé (s)
    var url: URL { Store.dir.appending(path: file) }
}
struct Playlist: Codable, Identifiable {
    var id = UUID()
    var name: String
    var cover: Data?
    var trackIDs: [UUID] = []
}
struct PlayEvent: Codable { var track: UUID; var date: Date }   // écoute validée (≥ 30 s)
struct DB: Codable {
    var tracks: [Track] = [], playlists: [Playlist] = [], events: [PlayEvent] = []
    var artistPhotos: [String: Data] = [:]
}

@MainActor @Observable final class Store {
    nonisolated static let dir: URL = {
        let d = URL.documentsDirectory.appending(path: "Music")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let dbURL = URL.documentsDirectory.appending(path: "library.json")
    var db = DB()
    @ObservationIgnored private var lastSaved = Data()

    init() {
        if let d = try? Data(contentsOf: Self.dbURL), let x = try? JSONDecoder().decode(DB.self, from: d) { db = x }
        Task { [weak self] in                       // sauvegarde automatique toutes les 2 s si modifié
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.persist()
            }
        }
    }
    func persist() {
        guard let d = try? JSONEncoder().encode(db), d != lastSaved else { return }
        lastSaved = d; try? d.write(to: Self.dbURL)
    }

    // MARK: Playlists
    /// Playlist « source » : tous les sons différents présents dans au moins une playlist
    var source: [Track] { let ids = Set(db.playlists.flatMap(\.trackIDs)); return db.tracks.filter { ids.contains($0.id) } }
    func tracks(of p: Playlist) -> [Track] { p.trackIDs.compactMap { id in db.tracks.first { $0.id == id } } }
    func track(_ id: UUID) -> Track? { db.tracks.first { $0.id == id } }
    func createPlaylist(_ name: String) { db.playlists.append(Playlist(name: name)) }
    func deletePlaylist(_ id: UUID) { db.playlists.removeAll { $0.id == id }; cleanup() }
    func remove(at o: IndexSet, from pid: UUID) {
        guard let i = db.playlists.firstIndex(where: { $0.id == pid }) else { return }
        db.playlists[i].trackIDs.remove(atOffsets: o); cleanup()
    }
    func setCover(_ d: Data, _ pid: UUID) {
        if let i = db.playlists.firstIndex(where: { $0.id == pid }) { db.playlists[i].cover = Self.thumb(d) }
    }
    func setArtistPhoto(_ d: Data, _ name: String) { db.artistPhotos[name] = Self.thumb(d) }
    private func cleanup() {
        let used = Set(db.playlists.flatMap(\.trackIDs))
        for t in db.tracks where !used.contains(t.id) { try? FileManager.default.removeItem(at: t.url) }
        db.tracks.removeAll { !used.contains($0.id) }
    }
    static func thumb(_ d: Data) -> Data? {
        guard let img = UIImage(data: d) else { return nil }
        let s = min(1, 600 / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: Import (m4a / mp4)
    func importFiles(_ urls: [URL], into pid: UUID) async {
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            var t = db.tracks.first { $0.file == u.lastPathComponent }   // pas de doublon
            if t == nil {
                let dest = Self.dir.appending(path: u.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: u, to: dest)) != nil else { continue }
                let a = AVURLAsset(url: dest)
                let dur = (try? await a.load(.duration).seconds) ?? 0
                let md = (try? await a.load(.commonMetadata)) ?? []
                let title = await text(md, .commonIdentifierTitle) ?? u.deletingPathExtension().lastPathComponent
                let artist = await text(md, .commonIdentifierArtist) ?? "Artiste inconnu"
                let n = Track(file: u.lastPathComponent, title: title, artist: artist, duration: dur.isFinite ? dur : 0)
                db.tracks.append(n); t = n
            }
            if let t, let i = db.playlists.firstIndex(where: { $0.id == pid }), !db.playlists[i].trackIDs.contains(t.id) {
                db.playlists[i].trackIDs.append(t.id)
            }
        }
    }
    private func text(_ md: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let it = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: id).first else { return nil }
        return try? await it.load(.stringValue)
    }

    // MARK: Statistiques
    func addListen(_ id: UUID, _ d: Double) { if let i = db.tracks.firstIndex(where: { $0.id == id }) { db.tracks[i].listened += d } }
    var unplayed: [Track] { let p = Set(db.events.map(\.track)); return source.filter { !p.contains($0.id) } }
    var artists: [String] { Array(Set(source.map(\.artist))).sorted() }
    var weekArtists: [(String, Int)] {
        let since = Date().addingTimeInterval(-7 * 86400); var c = [String: Int]()
        for e in db.events where e.date >= since { if let t = track(e.track) { c[t.artist, default: 0] += 1 } }
        return c.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
    var allTimeArtists: [(String, Double)] {
        var c = [String: Double](); for t in db.tracks { c[t.artist, default: 0] += t.listened }
        return c.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
    var totalTime: Double { db.tracks.reduce(0) { $0 + $1.listened } }
    var topTracks: [(Track, Int)] {
        var c = [UUID: Int](); for e in db.events { c[e.track, default: 0] += 1 }
        return c.compactMap { k, v in track(k).map { ($0, v) } }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }
}
