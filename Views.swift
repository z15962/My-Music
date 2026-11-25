import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
func hm(_ s: Double) -> String { let m = Int(s) / 60; return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min \(Int(s) % 60) s" }

struct Cover: View {
    var data: Data?, seed: String, icon = "music.note"
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit).overlay {
            if let d = data, let u = UIImage(data: d) { Image(uiImage: u).resizable().scaledToFill() }
            else {
                let h = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
                ZStack {
                    LinearGradient(colors: [Color(hue: h, saturation: 0.6, brightness: 0.85), Color(hue: h, saturation: 0.7, brightness: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.title).foregroundStyle(.white.opacity(0.85))
                }
            }
        }.clipped()
    }
}
struct MiniSpace: ViewModifier {
    @Environment(Player.self) var p
    func body(content: Content) -> some View { content.safeAreaInset(edge: .bottom) { Color.clear.frame(height: p.current == nil ? 0 : 70) } }
}
extension View { func miniSpace() -> some View { modifier(MiniSpace()) } }

struct RootView: View {
    @Environment(Store.self) var store
    @Environment(Player.self) var player
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                LibraryView().tabItem { Label("Librairie", systemImage: "music.note.list") }
                RecoView().tabItem { Label("Recommandations", systemImage: "sparkles") }
                ArtistsView().tabItem { Label("Artistes", systemImage: "music.mic") }
                StatsView().tabItem { Label("Statistiques", systemImage: "chart.bar.fill") }
            }
            MiniPlayer().padding(.bottom, 52)
        }.onAppear { player.store = store }
    }
}

// MARK: Librairie
struct LibraryView: View {
    @Environment(Store.self) var store
    @State private var adding = false, name = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 20) {
                    NavigationLink { PlaylistView(id: nil) } label: {
                        cell(Cover(data: nil, seed: "Toutes", icon: "music.note.list"), "Toutes les musiques", store.source.count)
                    }
                    ForEach(store.db.playlists) { p in
                        NavigationLink { PlaylistView(id: p.id) } label: { cell(Cover(data: p.cover, seed: p.name), p.name, p.trackIDs.count) }
                            .contextMenu { Button("Supprimer", role: .destructive) { store.deletePlaylist(p.id) } }
                    }
                }.padding().buttonStyle(.plain)
            }
            .miniSpace().navigationTitle("Librairie")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
            .alert("Nouvelle playlist", isPresented: $adding) {
                TextField("Nom", text: $name)
                Button("Créer") { if !name.isEmpty { store.createPlaylist(name) }; name = "" }
                Button("Annuler", role: .cancel) { name = "" }
            }
        }
    }
    func cell(_ c: Cover, _ t: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            c.clipShape(RoundedRectangle(cornerRadius: 10))
            Text(t).font(.subheadline.bold()).lineLimit(1)
            Text("\(n) titre\(n > 1 ? "s" : "")").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlaylistView: View {
    let id: UUID?                                  // nil = playlist source
    @Environment(Store.self) var store
    @Environment(Player.self) var player
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    var playlist: Playlist? { store.db.playlists.first { $0.id == id } }
    var tracks: [Track] { playlist.map { store.tracks(of: $0) } ?? store.source }
    var body: some View {
        List {
            VStack(spacing: 16) {
                if id != nil {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Cover(data: playlist?.cover, seed: playlist?.name ?? "").frame(width: 200).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").font(.title).padding(8) }
                    }
                } else { Cover(data: nil, seed: "Toutes", icon: "music.note.list").frame(width: 200).clipShape(RoundedRectangle(cornerRadius: 12)) }
                HStack(spacing: 12) {
                    Button { player.play(tracks, shuffle: false) } label: { Label("Lecture", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button { player.play(tracks, shuffle: true) } label: { Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }.frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(t: t).contentShape(Rectangle()).onTapGesture { player.play(tracks, start: i, shuffle: false) }
            }
            .onDelete { if let id { store.remove(at: $0, from: id) } }
            .deleteDisabled(id == nil)
        }
        .listStyle(.plain).miniSpace().navigationTitle(playlist?.name ?? "Toutes les musiques")
        .toolbar { if id != nil { Button { importing = true } label: { Image(systemName: "plus") } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Audio, .mpeg4Movie], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r, let id { Task { await store.importFiles(urls, into: id) } }
        }
        .onChange(of: photo) {
            Task { if let d = try? await photo?.loadTransferable(type: Data.self), let id { store.setCover(d, id) } }
        }
    }
}

struct TrackRow: View {
    let t: Track
    @Environment(Store.self) var store
    @Environment(Player.self) var player
    var body: some View {
        HStack(spacing: 12) {
            Cover(data: store.db.artistPhotos[t.artist], seed: t.artist).frame(width: 46).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(t.title).foregroundStyle(player.current?.id == t.id ? accentColor : .primary).lineLimit(1)
                Text(t.artist).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(clock(t.duration)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Recommandations = jamais écoutées
struct RecoView: View {
    @Environment(Store.self) var store
    @Environment(Player.self) var player
    var body: some View {
        NavigationStack {
            let list = store.unplayed
            Group {
                if list.isEmpty { ContentUnavailableView("Rien de nouveau", systemImage: "sparkles", description: Text("Toutes vos musiques ont déjà été écoutées.")) }
                else { List(Array(list.enumerated()), id: \.element.id) { i, t in
                    TrackRow(t: t).contentShape(Rectangle()).onTapGesture { player.play(list, start: i, shuffle: false) } }.listStyle(.plain) }
            }.miniSpace().navigationTitle("Recommandations")
        }
    }
}

// MARK: Artistes
struct ArtistsView: View {
    @Environment(Store.self) var store
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 20) {
                    ForEach(store.artists, id: \.self) { ArtistCell(name: $0) }
                }.padding()
            }.miniSpace().navigationTitle("Artistes")
        }
    }
}
struct ArtistCell: View {
    let name: String
    @Environment(Store.self) var store
    @State private var item: PhotosPickerItem?
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            VStack {
                Cover(data: store.db.artistPhotos[name], seed: name, icon: "person.fill").clipShape(Circle())
                Text(name).font(.caption.bold()).foregroundStyle(.primary).lineLimit(1)
            }
        }.onChange(of: item) { Task { if let d = try? await item?.loadTransferable(type: Data.self) { store.setArtistPhoto(d, name) } } }
    }
}

// MARK: Statistiques
struct StatsView: View {
    @Environment(Store.self) var store
    var body: some View {
        NavigationStack {
            List {
                Section("Top 5 artistes · cette semaine") {
                    ForEach(Array(store.weekArtists.enumerated()), id: \.offset) { i, a in row(i, a.0, "\(a.1) écoute\(a.1 > 1 ? "s" : "")") }
                }
                Section {
                    ForEach(Array(store.allTimeArtists.enumerated()), id: \.offset) { i, a in row(i, a.0, hm(a.1)) }
                } header: { Text("Top 5 artistes · de tous les temps") } footer: { Text("Temps d'écoute total : \(hm(store.totalTime))") }
                Section("Top 5 musiques") {
                    ForEach(Array(store.topTracks.enumerated()), id: \.offset) { i, t in row(i, t.0.title, "\(t.1) fois") }
                }
            }.miniSpace().navigationTitle("Statistiques")
        }
    }
    func row(_ i: Int, _ t: String, _ v: String) -> some View {
        HStack { Text("\(i + 1)").bold().foregroundStyle(accentColor).frame(width: 24); Text(t).lineLimit(1); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}

// MARK: Lecteur
struct MiniPlayer: View {
    @Environment(Player.self) var p
    @Environment(Store.self) var s
    @State private var full = false
    var body: some View {
        if let t = p.current {
            HStack(spacing: 12) {
                Cover(data: s.db.artistPhotos[t.artist], seed: t.artist).frame(width: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading) { Text(t.title).font(.subheadline.bold()).lineLimit(1); Text(t.artist).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { p.toggle() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                Button { p.next() } label: { Image(systemName: "forward.fill").font(.title3) }
            }
            .buttonStyle(.plain).padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 8)
            .onTapGesture { full = true }
            .sheet(isPresented: $full) { FullPlayer() }
        }
    }
}
struct FullPlayer: View {
    @Environment(Player.self) var p
    @Environment(Store.self) var s
    var body: some View {
        VStack(spacing: 22) {
            if let t = p.current {
                Cover(data: s.db.artistPhotos[t.artist], seed: t.artist).clipShape(RoundedRectangle(cornerRadius: 14)).padding(24)
                VStack { Text(t.title).font(.title2.bold()); Text(t.artist).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { p.elapsed }, set: { p.seek($0) }), in: 0...max(t.duration, 1))
                HStack { Text(clock(p.elapsed)); Spacer(); Text(clock(t.duration)) }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 36) {
                    Button { p.toggleShuffle() } label: { Image(systemName: "shuffle").font(.title3).foregroundStyle(p.shuffle ? accentColor : .secondary) }
                    Button { p.prev() } label: { Image(systemName: "backward.fill") }
                    Button { p.toggle() } label: { Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                    Button { p.next() } label: { Image(systemName: "forward.fill") }
                }.font(.title).buttonStyle(.plain)
            }
            Spacer()
        }.padding().presentationBackground(.black)
    }
}
