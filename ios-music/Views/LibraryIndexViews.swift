import Foundation
import SwiftUI

struct ArtistLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedArtist: LibrarySelection?
    @State private var sections: [IndexedSection<MusicArtist>] = []

    var body: some View {
        IndexedLibraryView(
            title: "艺术家",
            emptyTitle: "暂无艺术家",
            emptyIcon: "music.mic",
            sections: sections
        ) { artist in
            Button {
                selectedArtist = LibrarySelection(id: artist.id)
            } label: {
                ArtistIndexRow(artist: artist)
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(item: $selectedArtist) { selection in
            if let artist = store.artists.first(where: { $0.id == selection.id }) {
                ArtistDetailView(artist: artist)
            } else {
                ContentUnavailableView("艺术家不可用", systemImage: "music.mic")
            }
        }
        .onAppear {
            refreshSections()
        }
        .onChange(of: store.artists) { _, _ in
            refreshSections()
        }
    }

    private func refreshSections() {
        sections = PinyinIndexer.sections(for: store.artists, title: \.name)
    }
}

struct AlbumLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedAlbum: LibrarySelection?
    @State private var sections: [IndexedSection<MusicAlbum>] = []

    var body: some View {
        IndexedLibraryView(
            title: "专辑",
            emptyTitle: "暂无专辑",
            emptyIcon: "square.stack",
            sections: sections
        ) { album in
            Button {
                selectedAlbum = LibrarySelection(id: album.id)
            } label: {
                AlbumIndexRow(album: album)
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(item: $selectedAlbum) { selection in
            if let album = store.albums.first(where: { $0.id == selection.id }) {
                AlbumDetailView(album: album)
            } else {
                ContentUnavailableView("专辑不可用", systemImage: "square.stack")
            }
        }
        .onAppear {
            refreshSections()
        }
        .onChange(of: store.albums) { _, _ in
            refreshSections()
        }
    }

    private func refreshSections() {
        sections = PinyinIndexer.sections(for: store.albums, title: \.title)
    }
}

private struct LibrarySelection: Identifiable, Hashable {
    let id: String
}

private struct IndexedLibraryView<Item: Identifiable, Row: View>: View {
    let title: String
    let emptyTitle: String
    let emptyIcon: String
    let sections: [IndexedSection<Item>]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            Text(section.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 6, trailing: 18))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)

                            ForEach(section.items) { item in
                                row(item)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                                    .listRowSeparatorTint(Color.musicSeparatorStroke)
                                    .listRowBackground(Color.clear)
                            }
                        }
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.plain)
                .listSectionIndexVisibility(.visible)
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.bottom, 112)
                .background(Color.musicPageBackground.ignoresSafeArea())
            }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.large)
    }
}

private struct ArtistIndexRow: View {
    @EnvironmentObject private var store: AppStore
    let artist: MusicArtist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artist.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 24)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(artist.songs.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct AlbumIndexRow: View {
    @EnvironmentObject private var store: AppStore
    let album: MusicAlbum

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: album.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 7)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text([album.artist, album.yearText].filter { !$0.isEmpty }.joined(separator: " - "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(album.songs.count) 首歌曲")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.84))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct IndexedSection<Item: Identifiable>: Identifiable {
    let title: String
    let items: [Item]

    var id: String { title }
}

private enum PinyinIndexer {
    static func sections<Item>(for items: [Item], title: KeyPath<Item, String>) -> [IndexedSection<Item>] where Item: Identifiable {
        let grouped = Dictionary(grouping: items) { item in
            indexTitle(for: item[keyPath: title])
        }

        return grouped.keys
            .sorted(by: sectionSort)
            .compactMap { key in
                guard let values = grouped[key] else { return nil }
                let sorted = values.sorted {
                    $0[keyPath: title].localizedCaseInsensitiveCompare($1[keyPath: title]) == .orderedAscending
                }
                return IndexedSection(title: key, items: sorted)
            }
    }

    private static func indexTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        let mutable = NSMutableString(string: trimmed) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)

        let latin = String(mutable).uppercased()
        guard let scalar = latin.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(scalar) else {
            return "#"
        }

        return String(Character(scalar))
    }

    private static func sectionSort(_ left: String, _ right: String) -> Bool {
        if left == "#" { return false }
        if right == "#" { return true }
        return left < right
    }
}
