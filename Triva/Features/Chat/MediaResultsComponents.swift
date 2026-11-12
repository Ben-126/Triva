//
//  MediaResultsComponents.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable), commune aux images et aux vidéos

/// Répartition d'une liste de résultats entre ce qui s'affiche d'emblée et ce
/// qui attend derrière « afficher plus ». Un type nommé plutôt qu'un tuple :
/// deux vues le consomment et des tests le comparent.
nonisolated struct MediaInlineLayout: Sendable, Equatable {
    let visibleCount: Int
    let hiddenCount: Int
}

/// Logique d'affichage des résultats médias (tâche 1.6), partagée par
/// `ImageResultsView` et `VideoResultsView`. Port de la mise en page de
/// `src/components/SearchImages.tsx` et `SearchVideos.tsx` (web).
///
/// `nonisolated`, et uniquement des types primitifs ou génériques en entrée,
/// jamais `ImageSearchResult` / `VideoSearchResult` : ces deux structs ne sont
/// pas annotés dans `Core/Media/`, donc isolés au main actor sous
/// `-default-isolation=MainActor`, conformance `Equatable` comprise. Même
/// choix, pour la même raison, que `WeatherWidgetPresentation`.
///
/// Rangé dans `MediaResultsComponents.swift` avec les autres briques communes
/// aux deux sections (types d'état, en-tête, vignette, libellé d'échec),
/// sorties de `ImageResultsView.swift` pour tenir sous les 800 lignes.
nonisolated enum MediaResultsPresentation {

    // MARK: Proportions

    /// Case de la grille d'images : 4:3, pas le 16:9 (`aspect-video`) du web.
    /// Les photos sont surtout en 4:3 ou 3:2 ; une case 16:9 rogne le haut et
    /// le bas de toute image en portrait, souvent là où se trouve le sujet.
    static let imageTileAspectRatio: CGFloat = 4.0 / 3.0

    /// Vignette vidéo : 16:9, le format de la vidéo elle-même. Les vignettes
    /// YouTube (`hqdefault.jpg`, 480 × 360) sont en 4:3 avec des bandes
    /// noires : remplies (`scaledToFill`) dans un cadre 16:9, ce sont
    /// précisément ces bandes qui disparaissent.
    static let videoThumbnailAspectRatio: CGFloat = 16.0 / 9.0

    // MARK: Grille d'images

    /// 2 colonnes en largeur compacte (iPhone), comme le `grid-cols-2` du web.
    static let compactColumnCount = 2
    /// 3 colonnes ailleurs : la colonne de chat plafonne à 640 pt
    /// (`ChatView.contentMaxWidth`), soit des cases d'environ 200 pt.
    static let regularColumnCount = 3
    /// 1 colonne aux tailles de texte d'accessibilité : à deux colonnes, le
    /// domaine sous chaque case serait tronqué à quelques lettres, et une
    /// image en pleine largeur est justement ce qu'on veut voir en grand.
    static let accessibilityColumnCount = 1

    /// Rangées montrées avant la case « +N ».
    static let inlineRowCount = 2

    /// Jamais moins de 4 cases : le web en montre 4 (3 images + « View N
    /// more »). À une colonne, 4 cases empilées gardent un aperçu utile.
    static let minimumGridCapacity = 4

    static func columnCount(isCompactWidth: Bool, isAccessibilitySize: Bool) -> Int {
        if isAccessibilitySize { return accessibilityColumnCount }
        return isCompactWidth ? compactColumnCount : regularColumnCount
    }

    /// Cases affichées avant de replier : deux rangées pleines (6 à trois
    /// colonnes, plutôt qu'une rangée à moitié vide), 4 au minimum. L'entrée
    /// est bornée à `1...regularColumnCount`, ce qui exclut aussi tout
    /// dépassement d'entier dans la multiplication.
    static func gridCapacity(columnCount: Int) -> Int {
        let columns = min(max(1, columnCount), regularColumnCount)
        return max(minimumGridCapacity, columns * inlineRowCount)
    }

    /// Port de la règle du web (`images.length > 4` → 3 images + « View N
    /// more », sinon toutes), généralisée à une capacité quelconque : au-delà
    /// de la capacité, la dernière case devient « +N ». N vaut donc toujours au
    /// moins 2 : une case « +1 » prendrait la place de l'image qu'elle annonce.
    ///
    /// Capacité ramenée à 2 au minimum, pour garder au moins une vraie image
    /// devant le « +N » ; un total négatif compte pour zéro.
    static func gridLayout(totalCount: Int, capacity: Int) -> MediaInlineLayout {
        let total = max(0, totalCount)
        let safeCapacity = max(2, capacity)
        guard total > safeCapacity else {
            return MediaInlineLayout(visibleCount: total, hiddenCount: 0)
        }
        let visible = safeCapacity - 1
        return MediaInlineLayout(visibleCount: visible, hiddenCount: total - visible)
    }

    // MARK: Liste de vidéos

    /// 3 vidéos avant « Afficher les N autres vidéos », comme les 3 vidéos du
    /// web devant sa case « View N more ».
    static let videoListLimit = 3

    /// Même règle que `gridLayout`, pour une liste : le bouton s'ajoute après
    /// les lignes au lieu de remplacer une case, et n'apparaît que s'il cache
    /// au moins 2 vidéos (« 1 autre vidéo » coûterait la place de la ligne
    /// cachée). `total - safeLimit` ne peut pas déborder : `total ≥ 0` et
    /// `safeLimit ≥ 1`.
    static func listLayout(totalCount: Int, limit: Int) -> MediaInlineLayout {
        let total = max(0, totalCount)
        let safeLimit = max(1, limit)
        guard total - safeLimit > 1 else {
            return MediaInlineLayout(visibleCount: total, hiddenCount: 0)
        }
        return MediaInlineLayout(visibleCount: safeLimit, hiddenCount: total - safeLimit)
    }

    // MARK: Source

    /// Domaine affiché sous chaque résultat (« lemonde.fr ») : c'est lui qui
    /// fait de cette grille une liste de SOURCES, pas une galerie. Délègue à
    /// `SourceRanker.normalizedHost(of:)` (minuscules, sans `www.`) plutôt que
    /// de réécrire la même normalisation : deux règles censées produire le
    /// même domaine finissent toujours par diverger.
    ///
    /// `nil` reste possible malgré le filtre `https` du service, qui ne
    /// vérifie que le schéma : `https:chemin` n'a pas d'hôte. La vue n'affiche
    /// alors rien plutôt qu'un domaine inventé.
    static func sourceDomain(of url: URL) -> String? {
        SourceRanker.normalizedHost(of: url.absoluteString)
    }

    /// Garde la première occurrence de chaque clé, dans l'ordre reçu.
    ///
    /// Indispensable avant un `ForEach` : `ImageSearchResult.id` est l'URL de
    /// l'image, et rien n'en garantit l'unicité. SearXNG ne fusionne deux
    /// résultats que s'ils ont la même URL de PAGE ; deux pages trouvées par
    /// `bing images` et `google images` peuvent reprendre la même image. Deux
    /// `id` égaux dans un `ForEach` donnent un rendu indéfini et cassent
    /// `scrollPosition(id:)` dans la visionneuse.
    static func removingDuplicates<Item, Key: Hashable>(_ items: [Item], by key: (Item) -> Key) -> [Item] {
        var seenKeys = Set<Key>()
        return items.filter { seenKeys.insert(key($0)).inserted }
    }

    // MARK: Visionneuse

    /// Titre de la visionneuse : « 3 sur 10 ». `nil` pour une image seule
    /// (« 1 sur 1 » ne dit rien) ou un index hors bornes. `count > 1` est testé
    /// AVANT de former `0..<count`, qui planterait sur un `count` négatif.
    static func positionText(index: Int, count: Int) -> String? {
        guard count > 1, (0..<count).contains(index) else { return nil }
        return "\(index + 1) sur \(count)"
    }

    /// Index voisin pour les boutons précédent / suivant de la visionneuse
    /// macOS, ou `nil` aux extrémités : pas de bouclage, comme Photos.
    /// `addingReportingOverflow` : un décalage aberrant renvoie `nil` au lieu
    /// de faire planter l'app.
    static func neighborIndex(of index: Int, offset: Int, count: Int) -> Int? {
        let (target, overflow) = index.addingReportingOverflow(offset)
        let validIndices = 0..<max(0, count)
        guard !overflow, validIndices.contains(index), validIndices.contains(target) else { return nil }
        return target
    }

    // MARK: VoiceOver

    /// « titre, domaine » : le format de `SourcesListView` pour les sources
    /// texte. Une source se lit de la même façon, page, image ou vidéo.
    static func accessibilityLabel(title: String, domain: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let domain, !domain.isEmpty else { return trimmedTitle }
        return trimmedTitle.isEmpty ? domain : "\(trimmedTitle), \(domain)"
    }
}

/// Les deux sortes de résultats médias, et tout ce qui les distingue à
/// l'écran : textes, symbole, proportions des vignettes. Tout le reste des
/// deux sections est commun.
///
/// Libellés sans point final : ce sont des états (« Image indisponible »), pas
/// des phrases. Accords au féminin : « image » et « vidéo » le sont toutes deux.
nonisolated enum MediaResultsKind: Sendable {
    case images
    case videos

    var sectionTitle: String {
        switch self {
        case .images: "Images"
        case .videos: "Vidéos"
        }
    }

    /// Symbole SF du bouton de recherche, de l'état vide et des vignettes
    /// indisponibles.
    var symbolName: String {
        switch self {
        case .images: "photo"
        case .videos: "play.rectangle"
        }
    }

    var searchButtonTitle: String {
        switch self {
        case .images: "Rechercher des images"
        case .videos: "Rechercher des vidéos"
        }
    }

    var loadingText: String {
        switch self {
        case .images: "Recherche d'images…"
        case .videos: "Recherche de vidéos…"
        }
    }

    var emptyText: String {
        switch self {
        case .images: "Aucune image trouvée"
        case .videos: "Aucune vidéo trouvée"
        }
    }

    var failureText: String {
        switch self {
        case .images: "La recherche d'images a échoué"
        case .videos: "La recherche de vidéos a échoué"
        }
    }

    var thumbnailFailureText: String {
        switch self {
        case .images: "Image indisponible"
        case .videos: "Vignette indisponible"
        }
    }

    var thumbnailAspectRatio: CGFloat {
        switch self {
        case .images: MediaResultsPresentation.imageTileAspectRatio
        case .videos: MediaResultsPresentation.videoThumbnailAspectRatio
        }
    }

    /// Annonce VoiceOver de fin de recherche : « 1 image trouvée »,
    /// « 8 vidéos trouvées », ou le texte de l'état vide.
    func resultsAnnouncement(count: Int) -> String {
        switch count {
        case ...0: emptyText
        case 1: "1 \(singularNoun) trouvée"
        default: "\(count) \(pluralNoun) trouvées"
        }
    }

    /// Libellé du bouton qui déplie la section. La case de la grille n'affiche
    /// que « +7 » : VoiceOver doit entendre ce que fait le bouton, pas un
    /// symbole.
    func showMoreLabel(hiddenCount: Int) -> String {
        switch hiddenCount {
        case ...0: "Tout afficher"
        case 1: "Afficher 1 autre \(singularNoun)"
        default: "Afficher les \(hiddenCount) autres \(pluralNoun)"
        }
    }

    private var singularNoun: String {
        switch self {
        case .images: "image"
        case .videos: "vidéo"
        }
    }

    private var pluralNoun: String { "\(singularNoun)s" }
}

/// Les états d'une section média autres que « résultats affichés ».
nonisolated enum MediaResultsStatus: Sendable {
    /// Recherche pas encore demandée : bouton « Rechercher des… ».
    case idle
    case loading
    /// Recherche aboutie, sans aucun résultat exploitable.
    case empty
    /// Recherche échouée : message, puis « Réessayer ».
    case failed
}

// MARK: - Briques de vue communes

/// Intitulé de section (« IMAGES », « VIDÉOS ») au style des labels de section
/// de la DA (« ESSAIE » dans `TrivaHomeReferenceView`) : 11 pt medium,
/// `tracking(1.5)`, majuscules, `.tertiary`. `.caption2` (11 pt à la taille
/// par défaut) plutôt que `.system(size: 11)`, qui ne suivrait pas Dynamic Type.
///
/// Trait `.isHeader` : le rotor « En-têtes » de VoiceOver mène directement
/// aux résultats médias d'une longue conversation. C'est le rôle de cet
/// intitulé, qui ne serait sinon que du remplissage.
struct MediaResultsSectionHeader: View {
    let kind: MediaResultsKind

    var body: some View {
        Text(kind.sectionTitle)
            .font(.caption2.weight(.medium))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rendu des états communs (`MediaResultsStatus`) des deux sections.
///
/// Sobre par construction : une ligne de texte secondaire, et un bouton en
/// verre quand une action existe (`.buttonStyle(.glass)`, le style des actions
/// secondaires de la DA, comme les suggestions de `TrivaHomeReferenceView`).
/// Jamais de détail d'erreur : la phase `.failed` n'en transporte aucun (voir
/// `ImageResultsPhase`).
///
/// Pas de squelette de chargement façon web (`animate-pulse`) : des cases
/// grises sans contenu sont précisément le « carré vide inexpliqué » à éviter,
/// et une pulsation d'opacité est un calque semi-transparent animé. Une ligne
/// « Recherche d'images… » dit la même chose, honnêtement.
struct MediaResultsStatusView: View {
    let status: MediaResultsStatus
    let kind: MediaResultsKind
    /// Bouton de l'état `.idle` et « Réessayer » de `.failed`.
    let onSearch: () -> Void

    var body: some View {
        switch status {
        case .idle:
            Button(action: onSearch) {
                Label(kind.searchButtonTitle, systemImage: kind.symbolName)
            }
            .font(.subheadline)
            .buttonStyle(.glass)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(kind.loadingText)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .empty:
            Label(kind.emptyText, systemImage: kind.symbolName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label(kind.failureText, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: onSearch) {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
                .buttonStyle(.glass)
            }
        }
    }
}

/// Vignette chargée par `UncachedRemoteImage` (aucun cache, voir `UncachedImageLoader`) : cases de la grille d'images et lignes
/// de vidéos. Cadre aux proportions fixes de la sorte de média, image remplie
/// puis rognée (`scaledToFill`), un seul rayon de coin (20, DESIGN.md).
///
/// ## Trois états, jamais un cadre vide inexpliqué
/// Chargement : un `ProgressView` discret. Échec : symbole + « Image
/// indisponible » / « Vignette indisponible ». Succès : l'image, en fondu
/// court (0,2 s). Un cas futur inconnu d'`AsyncImagePhase` est traité comme
/// un chargement, l'état le plus neutre.
///
/// ## Fond neutre `.fill.tertiary` : écart assumé, à valider par Ben
/// DESIGN.md proscrit les calques semi-transparents, et les remplissages
/// système le sont. Il est gardé pour la même raison que l'exception « fondu
/// de bord de scroll » : il est FONCTIONNEL, pas décoratif. C'est la couleur
/// que le système prévoit pour un contenu pas encore chargé (celle du gabarit
/// de widget d'Xcode), elle disparaît sous l'image dès le chargement, et sans
/// elle une vignette en chargement ne serait qu'un spinner flottant sans cadre.
///
/// ## Mémoire
/// Le chargeur décode par ImageIO en réduisant le plus grand côté à
/// `UncachedImageLoader.thumbnailPixelSize` : une photo de 4 000 × 3 000 pixels
/// (≈ 48 Mo décodée par `AsyncImage`, que ce chargeur remplace) n'occupe plus que
/// quelques Mo par case. Les bornes qui s'y ajoutent, par ordre d'importance :
/// 1. le plafond des services : `maxResults = 10` par défaut dans
///    `ImageSearchService` et `VideoSearchService` (le `.slice(0, 10)` du
///    web) ;
/// 2. la grille repliée : 6 cases au plus tant que « +N » n'est pas touché
///    (`MediaResultsPresentation.gridLayout`) ;
/// 3. la paresse des conteneurs, seulement là où elle est garantie : la
///    visionneuse (`LazyHStack`, contenu direct de son `ScrollView`). Pas
///    dans le fil : `ChatView` empile ses messages dans un `VStack` ordinaire
///    (pas un `LazyVStack`), il faut donc compter qu'une grille dépliée crée
///    toutes ses cases.
/// Le téléchargement reste celui de l'image entière : une vraie miniature
/// serveur demanderait que `ImageSearchResult` porte le `thumbnail_src` de
/// SearXNG (au service de le faire, pas à cette vue) : à prévoir AVANT de
/// relever `maxResults`.
///
/// `contentShape` après `clipShape` : une image rognée garde sinon sa zone de
/// toucher d'origine, qui déborde sur les cases voisines.
struct MediaThumbnail: View {
    let url: URL
    let kind: MediaResultsKind

    var body: some View {
        Color.clear
            .aspectRatio(kind.thumbnailAspectRatio, contentMode: .fit)
            .overlay {
                UncachedRemoteImage(url: url, maxPixelSize: UncachedImageLoader.thumbnailPixelSize) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        MediaLoadFailureLabel(kind: kind)
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
    }
}

/// État d'échec d'une image : symbole + texte, centré dans son cadre.
/// Interne (et non `private`) : `ImageViewerPage`, dans `ImageResultsView.swift`,
/// l'affiche aussi.
struct MediaLoadFailureLabel: View {
    let kind: MediaResultsKind

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.title3)
                .accessibilityHidden(true)
            Text(kind.thumbnailFailureText)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
    }
}
