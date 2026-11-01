//
//  ImageResultsView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Images

/// État de la section images d'un message, piloté par l'intégrateur
/// (`ChatViewModel`, à l'étape suivante). Port des états implicites de
/// `SearchImages.tsx` (`images === null` avec son bouton, `loading`,
/// `images`), plus un état d'échec que le web n'a pas : un `fetch` qui y
/// échoue laisse le squelette de chargement affiché indéfiniment.
///
/// `.failed` ne porte AUCUN détail d'erreur, volontairement : la vue n'a rien
/// à en afficher (jamais de texte d'erreur brut dans l'UI, voir
/// `ChatViewModel.userFacingMessage(for:)`), et l'intégrateur n'a pas à
/// décider quoi en filtrer. `.loaded([])` est l'état « aucune image trouvée »,
/// distinct de `.failed` exactement comme `ImageSearchService.search`
/// distingue un tableau vide d'un `throw`.
///
/// Pas `nonisolated` : il embarque `ImageSearchResult`, isolé au main actor
/// (non annoté dans `ImageSearchService.swift`), dont la conformance
/// `Equatable` l'est donc aussi ; une enum `nonisolated` ne pourrait pas
/// synthétiser la sienne. `Sendable` et `Equatable` pour pouvoir être stockée
/// telle quelle dans `ChatViewModel.Message`, qui est les deux.
enum ImageResultsPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded([ImageSearchResult])
    case failed
}

/// Résultats de recherche d'images d'un message (tâche 1.6) : grille
/// `LazyVGrid` de vignettes, chacune avec le domaine de sa source. Port de
/// `src/components/SearchImages.tsx` (web), refait selon DESIGN.md.
///
/// ## Parcours
/// - `.idle` : bouton « Rechercher des images », comme le bouton du web. La
///   recherche coûte un appel au modèle (reformulation) plus une requête
///   SearXNG : l'intégrateur choisit de la lancer à la demande, ou d'office en
///   démarrant directement en `.loading`.
/// - `.loading`, `.failed`, `.loaded([])` : voir `MediaResultsStatusView`.
/// - `.loaded` : grille repliée à deux rangées (`gridLayout`), dont la
///   dernière case « +N » déplie le reste sur place.
/// - Toucher une image ouvre la visionneuse (plein écran sur iOS, feuille sur
///   macOS) : l'image en grand, son titre, son domaine et « Ouvrir la
///   source ». Un appui long (clic droit sur Mac) propose aussi « Ouvrir la
///   source » directement.
/// - La fin d'une recherche est annoncée à VoiceOver (« 8 images trouvées »),
///   seulement sur CHANGEMENT de phase : un message rouvert depuis
///   l'historique, déjà en `.loaded`, ne s'annonce pas.
///
/// ## Écarts assumés vis-à-vis du web
/// - Cases 4:3 au lieu de 16:9 (voir `imageTileAspectRatio`), et domaine
///   visible sous chaque case : le web n'en montre aucun.
/// - Pas d'agrandissement au survol ni de rétrécissement au clic : le style de
///   bouton système donne déjà le retour au toucher.
/// - Un état d'échec avec « Réessayer », absent du web.
///
/// ## Intégration (faite à l'étape suivante, pas ici)
/// À poser comme FRÈRE de la bulle assistant, jamais à l'intérieur, et dans le
/// `GlassEffectContainer` existant du fil de chat : la vue contient des
/// éléments de verre (boutons, case « +N ») et n'ouvre pas de conteneur
/// elle-même. `onSearch` doit rester stable (capturer l'identifiant du
/// message, pas le message) : il sert au premier lancement comme à
/// « Réessayer ».
///
/// Pas `Equatable`, contrairement aux cartes de widgets : la closure
/// `onSearch` ne se compare pas. La réévaluation reste bon marché (6 cases au
/// plus tant que la grille est repliée), et `AsyncImage` ne recharge rien tant
/// que l'identité d'une case ne change pas.
struct ImageResultsView: View {
    let phase: ImageResultsPhase
    /// Lance (ou relance) la recherche d'images : bouton de `.idle` et
    /// « Réessayer » de `.failed`.
    let onSearch: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Grille dépliée par la case « +N », repliée à chaque nouvelle recherche.
    @State private var isExpanded = false
    /// Image touchée : la visionneuse est présentée tant qu'elle n'est pas
    /// nulle. Présentation pilotée par la donnée elle-même, jamais un `Bool` à
    /// côté d'une donnée qui pourrait ne pas être prête.
    @State private var viewerSelection: ImageSearchResult?

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: phase) { _, newPhase in
                if case .loading = newPhase {
                    isExpanded = false
                }
                closeViewerIfImageGone(in: newPhase)
                Self.announce(newPhase)
            }
            #if os(iOS)
            .fullScreenCover(item: $viewerSelection) { selected in
                ImageResultsViewer(images: Self.uniqueImages(in: phase), initialImageID: selected.id)
            }
            #else
            .sheet(item: $viewerSelection) { selected in
                ImageResultsViewer(images: Self.uniqueImages(in: phase), initialImageID: selected.id)
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            MediaResultsStatusView(status: .idle, kind: .images, onSearch: onSearch)
        case .loading:
            MediaResultsStatusView(status: .loading, kind: .images, onSearch: onSearch)
        case .failed:
            MediaResultsStatusView(status: .failed, kind: .images, onSearch: onSearch)
        case .loaded(let images):
            let deduplicated = Self.uniqueImages(images)
            if deduplicated.isEmpty {
                MediaResultsStatusView(status: .empty, kind: .images, onSearch: onSearch)
            } else {
                grid(deduplicated)
            }
        }
    }

    private func grid(_ images: [ImageSearchResult]) -> some View {
        let columnCount = MediaResultsPresentation.columnCount(
            isCompactWidth: horizontalSizeClass == .compact,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        let capacity = isExpanded
            ? images.count
            : MediaResultsPresentation.gridCapacity(columnCount: columnCount)
        let layout = MediaResultsPresentation.gridLayout(totalCount: images.count, capacity: capacity)
        // Alignement `.top` : la case « +N » n'a pas de domaine dessous, elle
        // est plus courte que ses voisines ; centrée, elle serait décalée.
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
            count: columnCount
        )

        return VStack(alignment: .leading, spacing: 12) {
            MediaResultsSectionHeader(kind: .images)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(images.prefix(layout.visibleCount)) { image in
                    ImageResultTile(image: image) {
                        viewerSelection = image
                    }
                }
                if layout.hiddenCount > 0 {
                    MoreImagesTile(hiddenCount: layout.hiddenCount) {
                        withAnimation { isExpanded = true }
                    }
                }
            }
        }
    }

    /// `ImageSearchResult.id` est l'URL de l'image : dédupliquer sur
    /// `imageURL` revient à dédupliquer sur `id` (voir
    /// `MediaResultsPresentation.removingDuplicates`).
    private static func uniqueImages(_ images: [ImageSearchResult]) -> [ImageSearchResult] {
        MediaResultsPresentation.removingDuplicates(images) { $0.imageURL }
    }

    private static func uniqueImages(in phase: ImageResultsPhase) -> [ImageSearchResult] {
        guard case .loaded(let images) = phase else { return [] }
        return uniqueImages(images)
    }

    /// Ferme la visionneuse quand la nouvelle phase ne contient plus l'image
    /// affichée. Son contenu suit `phase` : si l'intégrateur relance la
    /// recherche (ou remplace le message) pendant qu'elle est ouverte, elle
    /// resterait sinon ouverte sur une liste vide, une page blanche avec
    /// seulement « Fermer ». Une image toujours listée (résultats complétés
    /// ou réordonnés) la laisse ouverte.
    private func closeViewerIfImageGone(in newPhase: ImageResultsPhase) {
        guard let selected = viewerSelection else { return }
        let isStillListed = Self.uniqueImages(in: newPhase).contains { $0.id == selected.id }
        if !isStillListed {
            viewerSelection = nil
        }
    }

    /// Sans cette annonce, l'utilisateur VoiceOver qui a touché « Rechercher
    /// des images » n'apprend rien quand le bouton disparaît : même principe
    /// que `ChatView.announce(error:)`.
    private static func announce(_ phase: ImageResultsPhase) {
        let message: String
        switch phase {
        case .loaded(let images):
            message = MediaResultsKind.images.resultsAnnouncement(count: uniqueImages(images).count)
        case .failed:
            message = MediaResultsKind.images.failureText
        case .idle, .loading:
            return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Une case de la grille : la vignette, puis le domaine de la source juste
/// dessous, jamais l'un sans l'autre. Domaine tronqué au MILIEU : la fin
/// (« …wikipedia.org ») est la partie qui identifie la source.
private struct ImageResultTile: View {
    let image: ImageSearchResult
    let onOpen: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let domain = MediaResultsPresentation.sourceDomain(of: image.sourceURL)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                MediaThumbnail(url: image.imageURL, kind: .images)
                if let domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MediaResultsPresentation.accessibilityLabel(title: image.title, domain: domain))
        .accessibilityHint("Affiche l'image en grand")
        .accessibilityAddTraits(.isImage)
        .help(image.title)
        .contextMenu {
            Button("Ouvrir la source", systemImage: "arrow.up.right.square") {
                openURL(image.sourceURL)
            }
        }
    }
}

/// Dernière case de la grille quand elle déborde : « +7 ». Déplie la grille
/// sur place plutôt que d'ouvrir la visionneuse : une vue d'ensemble se
/// parcourt mieux en grille qu'image par image.
///
/// Seul élément en verre de la grille (`.regular.interactive()`, c'est un
/// bouton) : les vignettes sont du CONTENU, et la DA réserve le verre aux
/// barres, badges et boutons. `contentShape` : sans lui, `Color.clear` ne
/// reçoit aucun toucher.
///
/// « +N » en `.title3`, la taille déjà prise par le symbole des vignettes
/// indisponibles : une taille de texte de moins à l'écran (DESIGN.md, 5
/// tailles au plus), pour un écart de 2 pt invisible dans une case de cette
/// taille.
private struct MoreImagesTile: View {
    let hiddenCount: Int
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Color.clear
                .aspectRatio(MediaResultsPresentation.imageTileAspectRatio, contentMode: .fit)
                .overlay {
                    Text("+\(hiddenCount)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .contentShape(.rect(cornerRadius: 20))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MediaResultsKind.images.showMoreLabel(hiddenCount: hiddenCount))
    }
}

/// Visionneuse plein écran (iOS) ou en feuille (macOS) : une image par page,
/// balayage horizontal entre les résultats. L'équivalent natif de la
/// `Lightbox` du web.
///
/// ## Démarrer sur la bonne page plutôt que réordonner
/// Le web réordonne les diapositives (`[slides[i], ...avant, ...après]`) pour
/// que l'image touchée passe en premier. Ici l'ordre d'origine est gardé et la
/// visionneuse démarre sur la page touchée (`scrollPosition(id:)` initialisé
/// dans `init`) : balayer vers la droite montre bien l'image précédente de la
/// grille, comme dans Photos.
///
/// ## Mac
/// Pas de balayage à la souris : boutons précédent / suivant sous l'image,
/// aussi au clavier (flèches). « Fermer » (`.cancellationAction`) répond à
/// Échap.
///
/// `LazyHStack` : seules les pages proches de l'écran existent, donc seules
/// leurs images sont chargées et décodées.
private struct ImageResultsViewer: View {
    let images: [ImageSearchResult]

    @State private var currentImageID: String?
    @Environment(\.dismiss) private var dismiss

    init(images: [ImageSearchResult], initialImageID: String) {
        self.images = images
        _currentImageID = State(initialValue: initialImageID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pager
                #if os(macOS)
                if images.count > 1 {
                    pageButtons
                }
                #endif
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }

    private var currentIndex: Int? {
        images.firstIndex { $0.id == currentImageID }
    }

    private var navigationTitle: String {
        guard let currentIndex else { return "" }
        return MediaResultsPresentation.positionText(index: currentIndex, count: images.count) ?? ""
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(images) { image in
                    ImageViewerPage(image: image)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentImageID)
        .scrollIndicators(.hidden)
    }

    #if os(macOS)
    private var pageButtons: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button("Image précédente", systemImage: "chevron.left") {
                    showNeighbor(offset: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(neighborImageID(offset: -1) == nil)

                Spacer()

                Button("Image suivante", systemImage: "chevron.right") {
                    showNeighbor(offset: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(neighborImageID(offset: 1) == nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func neighborImageID(offset: Int) -> String? {
        guard
            let currentIndex,
            let target = MediaResultsPresentation.neighborIndex(of: currentIndex, offset: offset, count: images.count)
        else { return nil }
        return images[target].id
    }

    private func showNeighbor(offset: Int) {
        guard let neighborID = neighborImageID(offset: offset) else { return }
        withAnimation { currentImageID = neighborID }
    }
    #endif
}

/// Une page de la visionneuse : l'image entière (`scaledToFit`, jamais
/// rognée), puis son titre, son domaine et « Ouvrir la source ». En grand
/// comme en vignette, une image reste une source citée.
///
/// Image et légende forment UN élément VoiceOver (« titre, domaine », trait
/// image) ; le bouton reste un élément à part, atteignable seul.
private struct ImageViewerPage: View {
    let image: ImageSearchResult

    @Environment(\.openURL) private var openURL

    var body: some View {
        let domain = MediaResultsPresentation.sourceDomain(of: image.sourceURL)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                fullImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(image.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                    if let domain {
                        Text(domain)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MediaResultsPresentation.accessibilityLabel(title: image.title, domain: domain))
            .accessibilityAddTraits(.isImage)

            Button {
                openURL(image.sourceURL)
            } label: {
                Label("Ouvrir la source", systemImage: "arrow.up.right.square")
            }
            .font(.subheadline)
            .buttonStyle(.glass)
        }
        .padding(20)
    }

    private var fullImage: some View {
        AsyncImage(url: image.imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let loadedImage):
                loadedImage
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 20))
            case .failure:
                MediaLoadFailureLabel(kind: .images)
            case .empty:
                ProgressView()
            @unknown default:
                ProgressView()
            }
        }
    }
}

// MARK: - Previews

/// Données factices des previews, sur la requête de test du plan (« chats
/// mignons »).
///
/// Images : PNG unis de 4 × 3 pixels encodés en `data:`, tous différents (la
/// grille déduplique sur l'URL de l'image, d'où 10 images au plus).
/// `URLSession`, que `AsyncImage` utilise, les sert sans aucun accès réseau
/// (vérifié : un `data:` renvoie ses octets et le type `image/png`). Jamais de
/// vrai réseau dans une preview, même règle que les previews de `ChatView`.
/// Les URLs `.example` (réservées par la RFC 2606, jamais résolues) montrent
/// l'état d'échec.
private enum ImageResultsPreviewData {
    static let solidImages = [
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mPIqeqEIwacHABOUBE1SlTxnQAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mNom1YFRww4OQBz4hMJUAwCAAAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEUlEQVR42mM4smkKHDHg5AAA35oYeZ1GEU4AAAAASUVORK5CYII=",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mOISWqAIwacHAAhMg7pq2+eQQAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mNY0FAARww4OQBwFhLBNMTy9wAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mOo6JkGRww4OQB1khM5kBqBLQAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mPYsKQFjhhwcgCxthYhTs7cTgAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mPIKEmBIwacHAAk5g8BXz2bsAAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mOY0rEAjhhwcgCVfhTRMcVzsAAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR42mPYNa0CjhhwcgCkHhVhwmZYZAAAAABJRU5ErkJggg==",
    ]

    static let titles = [
        "Chaton roux endormi au soleil",
        "Chat européen sur un rebord de fenêtre",
        "Deux chatons qui jouent avec une pelote",
        "Chat noir aux yeux verts",
        "Maine coon dans la neige",
        "Chaton tigré dans un panier",
        "Chat siamois allongé sur un canapé",
        "Chat qui bâille",
        "Chaton blanc aux yeux bleus",
        "Chat persan sur un coussin",
    ]

    static let sourcePages = [
        "https://fr.wikipedia.org/wiki/Chat",
        "https://www.lemonde.fr/animaux/",
        "https://unsplash.com/fr/s/photos/chaton",
        "https://www.pexels.com/fr-fr/chercher/chat/",
        "https://www.flickr.com/search/?text=chaton",
    ]

    static func images(count: Int, failing: Bool = false) -> [ImageSearchResult] {
        (0..<max(0, count)).compactMap { index -> ImageSearchResult? in
            let imageString = failing
                ? "https://images.preview.example/\(index).jpg"
                : solidImages[index % solidImages.count]
            guard
                let imageURL = URL(string: imageString),
                let sourceURL = URL(string: sourcePages[index % sourcePages.count])
            else { return nil }
            return ImageSearchResult(imageURL: imageURL, sourceURL: sourceURL, title: titles[index % titles.count])
        }
    }
}

#Preview("Images — grille") {
    ScrollView {
        ImageResultsView(phase: .loaded(ImageResultsPreviewData.images(count: 10)), onSearch: {})
            .padding(20)
    }
}

#Preview("Images — états") {
    GlassEffectContainer(spacing: 16) {
        VStack(alignment: .leading, spacing: 32) {
            ImageResultsView(phase: .idle, onSearch: {})
            ImageResultsView(phase: .loading, onSearch: {})
            ImageResultsView(phase: .loaded([]), onSearch: {})
            ImageResultsView(phase: .failed, onSearch: {})
        }
    }
    .padding(20)
}

#Preview("Images — vignettes indisponibles, sombre") {
    ScrollView {
        ImageResultsView(phase: .loaded(ImageResultsPreviewData.images(count: 4, failing: true)), onSearch: {})
            .padding(20)
    }
    .preferredColorScheme(.dark)
}

#Preview("Images — très grand texte") {
    ScrollView {
        ImageResultsView(phase: .loaded(ImageResultsPreviewData.images(count: 10)), onSearch: {})
            .padding(20)
    }
    .dynamicTypeSize(.accessibility3)
}

#Preview("Visionneuse") {
    let images = ImageResultsPreviewData.images(count: 5)
    return ImageResultsViewer(images: images, initialImageID: images.dropFirst().first?.id ?? "")
}
