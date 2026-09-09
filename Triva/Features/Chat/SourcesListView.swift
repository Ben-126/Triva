import SwiftUI

/// Liste simple des sources d'un message assistant : titre + lien
/// uniquement, aucun scoring visuel, aucune favicon ni image — même esprit
/// que la boucle `ForEach(result.sources)` qui existait dans `resultSection`
/// de `SearchTestSection` (`ContentView.swift`, test 0.7) avant d'être
/// remplacée par le vrai chat (0.8).
struct SourcesListView: View {
    let sources: [SearXNGSearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.title)
                        .font(.footnote.weight(.medium))
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension SearXNGSearchResult {
    init(previewTitle: String, previewURL: String) {
        self.init(
            title: previewTitle,
            url: previewURL,
            content: nil,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }
}

#Preview("Sources — clair") {
    SourcesListView(sources: [
        SearXNGSearchResult(previewTitle: "Documentation Swift Concurrency", previewURL: "https://developer.apple.com/documentation/swift/concurrency"),
        SearXNGSearchResult(previewTitle: "SearXNG — moteur de recherche", previewURL: "https://docs.searxng.org"),
    ])
    .padding(20)
}

#Preview("Sources — sombre") {
    SourcesListView(sources: [
        SearXNGSearchResult(previewTitle: "Documentation Swift Concurrency", previewURL: "https://developer.apple.com/documentation/swift/concurrency"),
        SearXNGSearchResult(previewTitle: "SearXNG — moteur de recherche", previewURL: "https://docs.searxng.org"),
    ])
    .padding(20)
    .preferredColorScheme(.dark)
}
