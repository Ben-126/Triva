import SwiftUI

/// Liste simple des sources d'un message assistant : titre + lien
/// uniquement, aucun scoring visuel, aucune favicon ni image — même esprit
/// que la boucle `ForEach(result.sources)` qui existait dans `resultSection`
/// de `SearchTestSection` (`ContentView.swift`, test 0.7) avant d'être
/// remplacée par le vrai chat (0.8).
///
/// Chaque source est un vrai `Link` tapable (ouvre l'URL dans le navigateur
/// par défaut) ET un seul élément d'accessibilité combiné portant le trait
/// `.isLink` — sans ça, VoiceOver traiterait titre et URL comme deux `Text`
/// quelconques (ni annoncés comme lien, ni regroupés en un seul swipe) et
/// épellerait l'URL brute lettre par lettre au lieu d'un nom d'hôte court
/// (voir `sourceRow(_:)` : le libellé d'accessibilité utilise `url.host`, pas
/// la chaîne brute).
struct SourcesListView: View {
    let sources: [SearXNGSearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources) { source in
                sourceRow(source)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: SearXNGSearchResult) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(source.title)
                .font(.footnote.weight(.medium))
                // `Link` teinte son contenu avec l'accent par défaut quand
                // rien ne l'en empêche — sans ce `.primary` explicite, le
                // titre passerait en bleu accent au lieu de rester au style
                // neutre qu'il avait avant l'ajout du `Link` (finding 5/6),
                // un changement visuel non demandé.
                .foregroundStyle(.primary)
            Text(source.url)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let url = URL(string: source.url), let host = url.host, !host.isEmpty {
            Link(destination: url) { content }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(source.title), \(host)")
                .accessibilityAddTraits(.isLink)
        } else {
            // URL non résoluble en `URL` (rare, mais pas impossible pour un
            // résultat de recherche mal formé) : pas de `Link` tapable dans ce
            // cas, mais un texte brut plutôt qu'un lien mort.
            content
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
