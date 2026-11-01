//
//  DiscoverArticleRow.swift
//  Triva
//
//  Created by ben podrojsky on 03/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Règles d'affichage d'un article Découvrir (tâche 1.8) : quelle URL un
/// toucher a le droit d'ouvrir, quelle vignette mérite d'être chargée, quel
/// extrait mérite d'être montré.
///
/// `nonisolated`, et uniquement des types primitifs en entrée, jamais
/// `DiscoverArticle` : ce struct n'est pas annoté dans `DiscoverService.swift`,
/// donc isolé au main actor sous `-default-isolation=MainActor`, conformance
/// `Equatable` comprise. Même piège, même parade que
/// `MediaResultsPresentation` (`MediaResultsComponents.swift`).
nonisolated enum DiscoverArticlePresentation {
    /// Schémas qu'un toucher a le droit d'ouvrir. Un article vient d'une
    /// instance SearXNG publique qu'on ne contrôle pas : une URL `tel:`,
    /// `facetime:` ou le lien profond d'une app tierce partirait sinon dans
    /// `openURL` et lancerait une autre app sur un simple toucher. Même
    /// principe que `CitationPresentation.isAllowedExternalLink`.
    static let openableSchemes: Set<String> = ["http", "https"]

    /// URL ouvrable d'un article, ou `nil` si elle n'est pas `http`/`https`
    /// avec un hôte. Un article sans URL ouvrable n'a rien à faire dans un
    /// fil d'actualité : `DiscoverViewModel.sanitized(_:)` l'écarte avant
    /// tout affichage.
    static func articleURL(from rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            openableSchemes.contains(scheme),
            let host = url.host(),
            !host.isEmpty
        else { return nil }
        return url
    }

    /// Vignette à charger, ou `nil` pour une ligne sans image.
    ///
    /// - `https` avec un hôte : chargée.
    /// - `data:image/…` : chargée. Aucun accès réseau (`URLSession` la décode
    ///   sur place), et c'est ce qui donne de vraies vignettes aux previews.
    /// - Tout le reste, `nil` : une image `http://` serait bloquée par ATS, et
    ///   une URL relative au protocole (`//cdn…`, fréquente dans les flux
    ///   d'actualité) n'a pas de schéma du tout. Mieux vaut une ligne texte
    ///   seul qu'un cadre de vignette condamné à afficher « Image
    ///   indisponible ».
    ///
    /// ÉCART assumé vis-à-vis du web : `page.tsx` jette tout article sans
    /// vignette (`blogs.filter(blog => blog.thumbnail)`). Ici l'article reste,
    /// sans image : son titre vaut plus que sa photo, et ce filtre viderait
    /// des sujets entiers sur une instance qui renvoie peu d'images.
    static func thumbnailURL(from imageURL: URL?) -> URL? {
        guard let imageURL, let scheme = imageURL.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https":
            guard let host = imageURL.host(), !host.isEmpty else { return nil }
            return imageURL
        case "data":
            return imageURL.absoluteString.lowercased().hasPrefix("data:image/") ? imageURL : nil
        default:
            return nil
        }
    }

    /// Texte prêt à afficher : espaces, tabulations et retours à la ligne
    /// fusionnés en un seul espace, bords rognés. Les extraits SearXNG sont
    /// souvent découpés dans du HTML et gardent ses sauts de ligne, qui
    /// casseraient un extrait limité à 2 lignes dès le premier mot.
    static func displayText(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Extrait à montrer sous le titre, ou `nil` s'il est vide ou s'il ne
    /// fait que répéter le titre (casse et accents ignorés) : DESIGN.md
    /// proscrit le sous-titre qui répète le titre, et plusieurs moteurs
    /// d'actualité recopient le titre dans `content` faute de résumé.
    static func snippet(_ raw: String?, title: String) -> String? {
        guard let raw else { return nil }
        let text = displayText(raw)
        guard !text.isEmpty else { return nil }
        let repeatsTitle = text.compare(
            displayText(title),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
        return repeatsTitle ? nil : text
    }

    /// Domaine de la source (« lemonde.fr ») : délègue à
    /// `SourceRanker.normalizedHost(of:)` (minuscules, sans `www.`), la règle
    /// déjà utilisée par le classement des sources et par les résultats
    /// médias. Deux normalisations censées produire le même domaine finissent
    /// toujours par diverger.
    static func sourceDomain(of rawURL: String) -> String? {
        SourceRanker.normalizedHost(of: rawURL)
    }
}

// MARK: - Ligne d'article

/// Une ligne du fil Découvrir : domaine de la source, titre, extrait court,
/// vignette à droite si l'article en a une. Port de `SmallNewsCard.tsx` /
/// `MajorNewsCard.tsx` (web), refait selon DESIGN.md.
///
/// ## Ce que fait un toucher
/// Ouvre l'article dans le navigateur par défaut (`openURL`), comme le
/// demande la mission 1.8. ÉCART assumé vis-à-vis du web, où un clic lance
/// une recherche Vane `/?q=Summary: <url>` : cette recherche existe ici aussi,
/// mais en action secondaire (`onSearch`), dans le menu contextuel (appui long
/// sur iOS, clic droit sur Mac) et en action VoiceOver. `onSearch` vaut `nil`
/// tant que l'intégration ne l'a pas câblée : l'entrée disparaît alors du
/// menu plutôt que de ne rien faire.
///
/// `Button` + `openURL` en `.buttonStyle(.plain)` plutôt que `Link` : un
/// `Link` teinte son contenu à l'accent (voir le correctif de
/// `SourcesListView`), le style `.plain` garde le titre en `.primary`. Pour
/// VoiceOver, la ligne est un LIEN (elle quitte l'app), pas un bouton — même
/// choix que `VideoResultRow`.
///
/// ## Sobriété (DESIGN.md)
/// - Ni verre ni fond de carte : une ligne d'article est du CONTENU, et la DA
///   réserve le verre aux barres, badges et boutons. L'espacement de la
///   grille suffit à séparer les articles, comme dans Actualités.
/// - Domaine AU-DESSUS du titre : c'est la convention des fils d'actualité
///   (l'éditeur avant le titre), et il donne un point d'accroche constant aux
///   lignes sans vignette.
/// - Vignette : `MediaThumbnail` (`MediaResultsComponents.swift`), donc même cadre
///   4:3, même rayon de 20 et mêmes états de chargement et d'échec que les
///   images du chat. Pas de date : `DiscoverArticle` n'en porte pas, et une
///   date inventée serait pire que pas de date.
///
/// ## Dynamic Type
/// Aux tailles d'accessibilité, la ligne passe en colonne (vignette en pleine
/// largeur au-dessus du texte), comme `VideoResultRow` : à côté d'une
/// vignette de 112 pt, un titre en très grand texte n'aurait plus qu'un mot
/// par ligne.
struct DiscoverArticleRow: View {
    let article: DiscoverArticle
    /// « Chercher dans Triva » : reçoit l'article entier, l'intégration
    /// décide de la requête (le web envoie `Summary: <url>`).
    let onSearch: ((DiscoverArticle) -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 112 pt de large (84 de haut en 4:3) : assez pour reconnaître l'image,
    /// et il reste environ 230 pt au texte sur iPhone (402 − 2 × 20 de marges
    /// − 112 − 12 d'espacement), soit une trentaine de caractères par ligne
    /// de titre.
    static let thumbnailWidth: CGFloat = 112

    init(article: DiscoverArticle, onSearch: ((DiscoverArticle) -> Void)? = nil) {
        self.article = article
        self.onSearch = onSearch
    }

    var body: some View {
        let title = DiscoverArticlePresentation.displayText(article.title)
        let domain = DiscoverArticlePresentation.sourceDomain(of: article.url)
        if let url = DiscoverArticlePresentation.articleURL(from: article.url) {
            Button {
                openURL(url)
            } label: {
                rowContent(title: title, domain: domain)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MediaResultsPresentation.accessibilityLabel(title: title, domain: domain))
            .accessibilityHint("Ouvre l'article dans ton navigateur")
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
            .accessibilityActions { searchAccessibilityAction }
            .contextMenu { contextMenuItems(url: url) }
            .help(title)
        } else {
            // Garde-fou : `DiscoverViewModel.sanitized(_:)` écarte déjà les
            // articles sans URL ouvrable. Si l'un passait quand même, on
            // l'affiche en texte seul plutôt qu'en lien mort.
            rowContent(title: title, domain: domain)
                .accessibilityElement(children: .combine)
        }
    }

    private var isAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var rowLayout: AnyLayout {
        isAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    /// `contentShape` : sans lui, seuls le texte et la vignette répondent au
    /// toucher, pas l'espace entre eux.
    private func rowContent(title: String, domain: String?) -> some View {
        let thumbnailURL = DiscoverArticlePresentation.thumbnailURL(from: article.imageURL)
        let snippet = DiscoverArticlePresentation.snippet(article.snippet, title: article.title)
        return rowLayout {
            if isAccessibilityLayout, let thumbnailURL {
                MediaThumbnail(url: thumbnailURL, kind: .images)
            }
            textColumn(title: title, domain: domain, snippet: snippet)
            if !isAccessibilityLayout, let thumbnailURL {
                MediaThumbnail(url: thumbnailURL, kind: .images)
                    .frame(width: Self.thumbnailWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// Domaine tronqué au MILIEU (« rmcsport.bf…tv.com ») : la fin est la
    /// partie qui identifie la source, comme sous les images du chat.
    private func textColumn(title: String, domain: String?, snippet: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let domain {
                Text(domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(isAccessibilityLayout ? nil : 3)
            if let snippet {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Chercher dans Triva » en premier : c'est l'action qui fait de
    /// Découvrir autre chose qu'un lecteur de flux, celle que le web met sur
    /// le clic principal.
    @ViewBuilder
    private func contextMenuItems(url: URL) -> some View {
        if let onSearch {
            Button("Chercher dans Triva", systemImage: "magnifyingglass") {
                onSearch(article)
            }
        }
        Button("Ouvrir l'article", systemImage: "arrow.up.right.square") {
            openURL(url)
        }
        ShareLink(item: url) {
            Label("Partager", systemImage: "square.and.arrow.up")
        }
    }

    /// La même recherche, à un balayage de distance pour VoiceOver : le menu
    /// contextuel demande un appui long, peu pratique au lecteur d'écran.
    @ViewBuilder
    private var searchAccessibilityAction: some View {
        if let onSearch {
            Button("Chercher dans Triva") {
                onSearch(article)
            }
        }
    }
}

// MARK: - Données factices des previews

/// Articles factices des previews de `DiscoverArticleRow` et de
/// `DiscoverView` (d'où `internal` plutôt que `private`, contrairement aux
/// données de preview des autres vues). Domaines en `.example` (jamais
/// résolus, et jamais un vrai média à qui l'on prêterait un titre inventé).
/// Vignettes : PNG unis encodés en `data:`, servis par `URLSession` sans
/// aucun réseau (mêmes images que les previews de `VideoResultsView`).
///
/// Couvre les cas de mise en page : article sans extrait, article sans
/// image, extrait qui répète le titre (masqué), sujet assez fourni pour le
/// bouton « Afficher les N autres articles ».
enum DiscoverPreviewData {
    private static let solidImages = [
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAE0lEQVR42mPIqeokCTGMahgUGgDLQM5xkJ/T2AAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR42mNom1ZFEmIY1TAoNAAAyKXkYdDyjhoAAAAASUVORK5CYII=",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR42mM4smkKSYhhVMOg0AAAE9wlsE7gwVcAAAAASUVORK5CYII=",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAE0lEQVR42mOISWogCTGMahgUGgAIb7Lh1f7whQAAAABJRU5ErkJggg==",
    ]

    static let techArticles: [DiscoverArticle] = [
        article(.tech, 0, "Les batteries solides passent le cap de la production en série",
                snippet: "Plusieurs constructeurs annoncent leurs premiers modèles équipés pour l'an prochain."),
        article(.tech, 1, "Un nouveau standard Wi-Fi promet des débits doublés à la maison", snippet: nil),
        article(.tech, 2, "Comment les puces basse consommation changent les centres de données",
                snippet: "Moins de chaleur à évacuer, des salles plus petites : les exploitants revoient leurs plans.",
                hasImage: false),
        article(.tech, 3, "Open source : une fondation reprend un outil clé du Web",
                snippet: "Open source : une fondation reprend un outil clé du Web"),
        article(.tech, 4, "Les lunettes connectées gagnent enfin en autonomie",
                snippet: "Une journée complète d'usage devient la norme sur les modèles récents."),
        article(.tech, 5, "La fibre couvre désormais la majorité des foyers",
                snippet: "Les zones rurales restent en retrait malgré l'accélération des raccordements."),
    ]

    static let content = DiscoverContent(
        sections: [
            DiscoverTopicSection(topic: .tech, articles: techArticles),
            DiscoverTopicSection(topic: .finance, articles: [
                article(.finance, 0, "Les taux d'emprunt baissent pour le troisième mois consécutif",
                        snippet: "Les courtiers observent un retour progressif des primo-accédants."),
                article(.finance, 1, "Les PME misent sur l'export face à un marché intérieur atone",
                        snippet: nil, hasImage: false),
            ]),
            DiscoverTopicSection(topic: .art, articles: [
                article(.art, 0, "Une exposition retrace un siècle d'affiches de cinéma",
                        snippet: "Plus de deux cents pièces originales, dont certaines jamais montrées."),
            ]),
            DiscoverTopicSection(topic: .sports, articles: [
                article(.sports, 0, "Le club local décroche sa place en demi-finale",
                        snippet: "Une victoire arrachée dans les dernières minutes, devant un stade comble."),
            ]),
            DiscoverTopicSection(topic: .entertainment, articles: [
                article(.entertainment, 0, "La série phare de l'automne annonce une deuxième saison",
                        snippet: nil),
            ]),
        ],
        failedTopics: []
    )

    /// Sport et Divertissement en échec : la vue « Tout » les omet, leur
    /// puce mène à l'état « Aucun article ».
    static let partialContent = DiscoverContent(
        sections: content.sections.filter { $0.topic != .sports && $0.topic != .entertainment },
        failedTopics: [.sports, .entertainment]
    )

    /// Aucun sujet n'a répondu : ce que renvoie `fetchTrending` hors ligne.
    static let allFailedContent = DiscoverContent(sections: [], failedTopics: DiscoverTopic.allCases)

    private static func article(
        _ topic: DiscoverTopic,
        _ index: Int,
        _ title: String,
        snippet: String?,
        hasImage: Bool = true
    ) -> DiscoverArticle {
        DiscoverArticle(
            topic: topic,
            result: SearXNGSearchResult(
                title: title,
                url: "https://\(topic.rawValue).journal.example/articles/\(index)",
                content: snippet,
                imgSrc: hasImage ? solidImages[index % solidImages.count] : nil,
                thumbnailSrc: nil,
                thumbnail: nil,
                author: nil,
                iframeSrc: nil
            )
        )
    }
}

// MARK: - Previews

#Preview("Article — avec et sans vignette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(DiscoverPreviewData.techArticles) { article in
                DiscoverArticleRow(article: article, onSearch: { _ in })
            }
        }
        .padding(20)
    }
}

#Preview("Article — sombre") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(DiscoverPreviewData.techArticles) { article in
                DiscoverArticleRow(article: article)
            }
        }
        .padding(20)
    }
    .preferredColorScheme(.dark)
}

#Preview("Article — très grand texte") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(DiscoverPreviewData.techArticles.prefix(2)) { article in
                DiscoverArticleRow(article: article, onSearch: { _ in })
            }
        }
        .padding(20)
    }
    .dynamicTypeSize(.accessibility3)
}
