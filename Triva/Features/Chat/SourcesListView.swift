import SwiftUI

/// Logique pure de `SourcesListView`, testée dans
/// `MessageBubblePresentationTests.swift`.
nonisolated enum SourcesListPresentation {
    /// Symbole d'une source tirée d'un fichier joint (1.11).
    static let attachmentSymbolName = "doc.text"

    /// Source tirée d'un fichier joint plutôt que du web : reconnue à son URL
    /// synthétique `triva-attachment:<UUID>`
    /// (`UploadsSearchResultBuilder.attachmentID(fromSourceURL:)`), sans
    /// dépendre de `attachmentSourceCount` ni de l'ordre des sources.
    static func isAttachment(_ source: SearXNGSearchResult) -> Bool {
        UploadsSearchResultBuilder.attachmentID(fromSourceURL: source.url) != nil
    }

    /// « rapport.pdf, fichier joint » : VoiceOver doit savoir qu'aucun lien
    /// ne s'ouvre ici, et que la source est un document de l'utilisateur.
    static func attachmentAccessibilityLabel(title: String) -> String {
        "\(FileAttachmentPresentation.displayName(for: title)), fichier joint"
    }

    /// Mention d'une source affichée mais jamais lue (mission C1, rapport E2).
    static let unreadLabel = "non lue"

    /// Ce qui s'affiche sous le titre d'une source web : le domaine seul, sans `www.`
    /// (« lemonde.fr »), comme Découvrir. Avant la mission C1, l'URL brute et percent-encodée
    /// (« …culmine-d%C3%A9sormais-%C3%A0-330-m… ») courait sur trois lignes, et sur douze à AX3
    /// (QA Q3, finding 6). Même règle que la fiche d'une citation
    /// (`CitationPresentation.displayHost`). `nil` pour une URL sans hôte lisible.
    static func displayDomain(for source: SearXNGSearchResult) -> String? {
        CitationPresentation.displayHost(for: source)
    }

    /// Adresse qu'un toucher sur la source ouvre : une page web (http ou https) seulement. Une instance
    /// de recherche publique, qu'on ne maîtrise pas, peut renvoyer `facetime://`, `tel://` ou
    /// `shortcuts://` : un lien vers une autre app n'a rien à faire dans une liste de sources (revue
    /// R3-3). Plus strict que `CitationPresentation.isAllowedExternalLink`, qui admet aussi `mailto`.
    /// `nil` : la ligne s'affiche en texte, sans lien.
    static func openableURL(for source: SearXNGSearchResult) -> URL? {
        guard let url = URL(string: source.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Libellé VoiceOver d'une source web : son numéro (celui des citations), son titre, son
    /// domaine, et « non lue » le cas échéant.
    static func webAccessibilityLabel(number: Int, title: String, domain: String, isUnread: Bool) -> String {
        let base = "Source \(number), \(title), \(domain)"
        return isUnread ? "\(base), \(unreadLabel)" : base
    }
}

/// Liste simple des sources d'un message assistant : titre + lien
/// uniquement, aucun scoring visuel, aucune favicon ni image — même esprit
/// que la boucle `ForEach(result.sources)` qui existait dans `resultSection`
/// de `SearchTestSection` (`ContentView.swift`, test 0.7) avant d'être
/// remplacée par le vrai chat (0.8).
///
/// Chaque source web est un vrai `Link` tapable (ouvre l'URL dans le
/// navigateur par défaut) ET un seul élément d'accessibilité combiné portant
/// le trait `.isLink` — sans ça, VoiceOver traiterait titre et URL comme deux
/// `Text` quelconques (ni annoncés comme lien, ni regroupés en un seul swipe)
/// et épellerait l'URL brute lettre par lettre au lieu d'un nom d'hôte court
/// (voir `sourceRow(_:)` : le libellé d'accessibilité utilise `url.host`, pas
/// la chaîne brute).
///
/// Une source tirée d'un fichier joint (1.11) n'a pas d'adresse à ouvrir :
/// une icône de document et son nom, sans lien ni seconde ligne. Avant,
/// sa seconde ligne affichait l'URL synthétique interne
/// (`triva-attachment:<UUID>`), un identifiant sans aucun sens pour
/// l'utilisateur.
struct SourcesListView: View {
    let sources: [SearXNGSearchResult]
    /// Numéros (1-based) des sources jamais lues (`Message.uncitableSourceNumbers`) : marquées
    /// sobrement « non lue », sans être retirées (elles gardent leur rang, donc leur numéro).
    var unreadNumbers: Set<Int> = []

    var body: some View {
        // 12 entre deux sources, 4 entre titre et domaine : avant, le même écart séparait
        // titre/URL et URL/titre suivant, on ne voyait pas ce qui allait ensemble (finding 6).
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sources.enumerated()), id: \.offset) { offset, source in
                sourceRow(source, number: offset + 1)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: SearXNGSearchResult, number: Int) -> some View {
        if SourcesListPresentation.isAttachment(source) {
            attachmentRow(source, number: number)
        } else {
            webRow(source, number: number)
        }
    }

    /// Numéro de la source, au style des pastilles de citation (`CitationPresentation.badgeFont`,
    /// accent) : `[2]` dans le texte se relie d'un coup d'œil à la deuxième source (finding 9).
    /// Largeur fixe pour aligner les titres ; masqué pour VoiceOver, qui le lit dans le libellé.
    private func numberLabel(_ number: Int) -> some View {
        Text(verbatim: "\(number)")
            .font(CitationPresentation.badgeFont)
            .monospacedDigit()
            .foregroundStyle(.tint)
            .frame(minWidth: 16, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func attachmentRow(_ source: SearXNGSearchResult, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            numberLabel(number)
            Label(FileAttachmentPresentation.displayName(for: source.title), systemImage: SourcesListPresentation.attachmentSymbolName)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source \(number), " + SourcesListPresentation.attachmentAccessibilityLabel(title: source.title))
    }

    @ViewBuilder
    private func webRow(_ source: SearXNGSearchResult, number: Int) -> some View {
        let domain = SourcesListPresentation.displayDomain(for: source)
        let isUnread = unreadNumbers.contains(number)
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            numberLabel(number)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.footnote.weight(.medium))
                    // `Link` teinte son contenu avec l'accent par défaut : `.primary` explicite
                    // garde le titre neutre (finding 5/6).
                    .foregroundStyle(.primary)
                // Une seule ligne, coupée au milieu si besoin : un domaine reste reconnaissable
                // par son début et sa fin, et n'est jamais césuré.
                Text(domainLine(domain: domain ?? source.url, isUnread: isUnread))
                    .font(.caption)
                    // Même encre que les légendes de la réponse : en `.secondary`, le domaine
                    // mesurait 2,86:1 sur le verre en clair (décision de Ben, 4,5:1 visés).
                    .foregroundStyle(MessageBubbleView.legendStyle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        if let url = SourcesListPresentation.openableURL(for: source), let domain {
            // `.plain` et `.leading`, constatés indispensables à l'écran (QA Q1, iOS 27) : le style
            // automatique d'un `Link` pose l'accent comme couleur de premier plan, et `.primary` /
            // `.secondary`, hiérarchiques, en héritent ; il centre aussi tout texte sur plusieurs lignes.
            Link(destination: url) { content }
                .buttonStyle(.plain)
                .multilineTextAlignment(.leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SourcesListPresentation.webAccessibilityLabel(
                    number: number, title: source.title, domain: domain, isUnread: isUnread
                ))
                .accessibilityAddTraits(.isLink)
                .accessibilityIdentifier("source.link")
        } else {
            // URL sans hôte lisible ou hors http(s) : du texte plutôt qu'un lien mort ou une autre app.
            content
        }
    }

    /// « lemonde.fr » ou « lemonde.fr · non lue » : la mention reste sur la ligne du domaine,
    /// discrète, sans couleur ni icône.
    private func domainLine(domain: String, isUnread: Bool) -> String {
        isUnread ? "\(domain) · \(SourcesListPresentation.unreadLabel)" : domain
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

#Preview("Sources — une non lue, AX3") {
    SourcesListView(
        sources: [
            SearXNGSearchResult(previewTitle: "La tour Eiffel culmine désormais à 330 mètres", previewURL: "https://www.lemonde.fr/culture/article/2026/03/15/la-tour-eiffel-culmine-d%C3%A9sormais-%C3%A0-330-m%C3%A8tres"),
            SearXNGSearchResult(previewTitle: "SearXNG — moteur de recherche", previewURL: "https://docs.searxng.org"),
        ],
        unreadNumbers: [2]
    )
    .padding(20)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Sources — fichier joint puis web") {
    SourcesListView(sources: [
        SearXNGSearchResult(
            previewTitle: "rapport-annuel-2026.pdf",
            previewURL: UploadsSearchResultBuilder.sourceURL(for: UUID())
        ),
        SearXNGSearchResult(previewTitle: "SearXNG — moteur de recherche", previewURL: "https://docs.searxng.org"),
    ])
    .padding(20)
}
