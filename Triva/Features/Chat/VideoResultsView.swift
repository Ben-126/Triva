//
//  VideoResultsView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

/// État de la section vidéos d'un message. Même contrat que
/// `ImageResultsPhase` (voir sa documentation) : `.failed` sans aucun détail
/// d'erreur, `.loaded([])` pour « aucune vidéo trouvée », et pas `nonisolated`
/// parce que `VideoSearchResult` est isolé au main actor.
enum VideoResultsPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded([VideoSearchResult])
    case failed
}

/// Résultats de recherche vidéo d'un message (tâche 1.6) : une liste dont
/// chaque ligne montre la vignette, le titre et le domaine de la source. Port
/// de la version web d'origine, refait selon DESIGN.md. Les
/// briques communes avec les images (`MediaThumbnail`,
/// `MediaResultsStatusView`, `MediaResultsPresentation`…) vivent dans
/// `MediaResultsComponents.swift`.
///
/// ## Toucher une vidéo l'ouvre hors de l'app
/// `openURL(sourceURL)` : la page de la vidéo, dans le navigateur par défaut,
/// ou dans l'app YouTube si elle est installée (le système suit les liens
/// universels). Jamais `embedURL` : c'est l'adresse d'un `<iframe>` (voir
/// `VideoSearchResult`), pas une page faite pour être ouverte telle quelle.
///
/// ## Écarts assumés vis-à-vis de la version web d'origine
/// - Une LISTE plutôt que la grille de la version web d'origine, comme le demande le plan : le
///   titre d'une vidéo en dit souvent plus que sa vignette.
/// - Pas de lecteur intégré (la `Lightbox` de la version web d'origine lit l'`iframe` sur place) :
///   la lecture intégrée est une piste V2, `embedURL` est conservé pour ça.
/// - Pas de pastille « Video » sur chaque vignette : l'intitulé « VIDÉOS » le
///   dit une fois pour toutes, et la pastille de la version web d'origine est un calque
///   semi-transparent, interdit par la DA.
/// - 3 vidéos d'emblée, puis « Afficher les N autres vidéos » (voir
///   `MediaResultsPresentation.listLayout`).
///
/// ## Dynamic Type
/// Aux tailles d'accessibilité, chaque ligne passe en colonne (vignette en
/// pleine largeur au-dessus du titre) : à côté d'une vignette de 160 pt, un
/// titre en très grand texte n'aurait plus qu'un mot par ligne. Test sur
/// `isAccessibilitySize` plutôt que `ViewThatFits` : un titre peut toujours
/// passer à la ligne, `ViewThatFits` jugerait donc la disposition en ligne
/// « trop large » à presque toutes les tailles.
///
/// ## Intégration (faite à l'étape suivante, pas ici)
/// Mêmes règles que `ImageResultsView` : FRÈRE de la bulle assistant, dans le
/// `GlassEffectContainer` existant du fil de chat, `onSearch` stable. Pas
/// `Equatable`, pour la même raison (la closure ne se compare pas).
struct VideoResultsView: View {
    let phase: VideoResultsPhase
    /// Lance (ou relance) la recherche de vidéos : bouton de `.idle` et
    /// « Réessayer » de `.failed`.
    let onSearch: () -> Void

    /// Liste dépliée par « Afficher les N autres vidéos », repliée à chaque
    /// nouvelle recherche.
    @State private var isExpanded = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: phase) { _, newPhase in
                if case .loading = newPhase {
                    isExpanded = false
                }
                Self.announce(newPhase)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            MediaResultsStatusView(status: .idle, kind: .videos, onSearch: onSearch)
        case .loading:
            MediaResultsStatusView(status: .loading, kind: .videos, onSearch: onSearch)
        case .failed:
            MediaResultsStatusView(status: .failed, kind: .videos, onSearch: onSearch)
        case .loaded(let videos):
            let deduplicated = Self.uniqueVideos(videos)
            if deduplicated.isEmpty {
                MediaResultsStatusView(status: .empty, kind: .videos, onSearch: onSearch)
            } else {
                list(deduplicated)
            }
        }
    }

    private func list(_ videos: [VideoSearchResult]) -> some View {
        let limit = isExpanded ? videos.count : MediaResultsPresentation.videoListLimit
        let layout = MediaResultsPresentation.listLayout(totalCount: videos.count, limit: limit)

        return VStack(alignment: .leading, spacing: 12) {
            MediaResultsSectionHeader(kind: .videos)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(videos.prefix(layout.visibleCount)) { video in
                    VideoResultRow(video: video)
                }
            }
            if layout.hiddenCount > 0 {
                Button {
                    withAnimation { isExpanded = true }
                } label: {
                    Label(
                        MediaResultsKind.videos.showMoreLabel(hiddenCount: layout.hiddenCount),
                        systemImage: "chevron.down"
                    )
                }
                .font(.subheadline)
                .buttonStyle(.glass)
            }
        }
    }

    /// `VideoSearchResult.id` est l'URL de la page : dédupliquer sur
    /// `sourceURL` revient à dédupliquer sur `id`. Le service ne déduplique
    /// pas, et deux `id` égaux dans un `ForEach` donnent un rendu indéfini.
    private static func uniqueVideos(_ videos: [VideoSearchResult]) -> [VideoSearchResult] {
        MediaResultsPresentation.removingDuplicates(videos) { $0.sourceURL }
    }

    /// Même rôle que l'annonce de `ImageResultsView` : dire à VoiceOver que la
    /// recherche est finie, seulement sur CHANGEMENT de phase.
    private static func announce(_ phase: VideoResultsPhase) {
        let message: String
        switch phase {
        case .loaded(let videos):
            message = MediaResultsKind.videos.resultsAnnouncement(count: uniqueVideos(videos).count)
        case .failed:
            message = MediaResultsKind.videos.failureText
        case .idle, .loading:
            return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Une ligne de la liste : vignette 16:9, titre (3 lignes au plus) et domaine.
///
/// `Button` + `openURL` avec `.buttonStyle(.plain)` plutôt que `Link` : un
/// `Link` teinte son contenu à l'accent (voir le correctif de
/// `SourcesListView`), le style `.plain` garde le titre en `.primary` sans
/// rien forcer. Pour VoiceOver, la ligne est annoncée comme un LIEN (elle
/// quitte l'app), pas comme un bouton.
private struct VideoResultRow: View {
    let video: VideoSearchResult

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    /// 160 × 90 en 16:9 : assez grand pour reconnaître la vidéo, assez petit
    /// pour laisser au titre environ 170 pt sur iPhone (393 − 2 × 20 de marges
    /// − 160 − 12 d'espacement).
    private static let thumbnailWidth: CGFloat = 160

    var body: some View {
        let domain = MediaResultsPresentation.sourceDomain(of: video.sourceURL)
        Button {
            openURL(video.sourceURL)
        } label: {
            rowLayout {
                MediaThumbnail(url: video.thumbnailURL, kind: .videos)
                    .frame(width: isAccessibilityLayout ? nil : Self.thumbnailWidth)
                details(domain: domain)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MediaResultsPresentation.accessibilityLabel(title: video.title, domain: domain))
        .accessibilityHint("Ouvre la page de la vidéo")
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
        .help(video.title)
    }

    private var isAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var rowLayout: AnyLayout {
        isAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    private func details(domain: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            if let domain {
                Text(domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Previews

/// Données factices des previews, sur la requête de test du plan (« chats
/// mignons »). Vignettes : PNG unis 16:9 encodés en `data:`, servis par
/// `URLSession` sans aucun réseau (même principe que les previews de
/// `ImageResultsView`) ; elles peuvent se répéter, la liste déduplique sur
/// l'URL de la PAGE. Les URLs `.example` (jamais résolues) montrent l'état
/// d'échec.
private enum VideoResultsPreviewData {
    static let solidThumbnails = [
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAE0lEQVR42mPIqeokCTGMahgUGgDLQM5xkJ/T2AAAAABJRU5ErkJggg==",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR42mNom1ZFEmIY1TAoNAAAyKXkYdDyjhoAAAAASUVORK5CYII=",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAFElEQVR42mM4smkKSYhhVMOg0AAAE9wlsE7gwVcAAAAASUVORK5CYII=",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAE0lEQVR42mOISWogCTGMahgUGgAIb7Lh1f7whQAAAABJRU5ErkJggg==",
    ]

    static let titles = [
        "Pourquoi les chats ronronnent-ils ?",
        "Une journée avec des chatons de huit semaines",
        "Comment un chat retombe toujours sur ses pattes",
        "Les chats reconnaissent-ils leur prénom ?",
        "Apprendre à un chaton à utiliser sa litière",
    ]

    static func videos(failingThumbnails: Bool = false) -> [VideoSearchResult] {
        titles.indices.compactMap { index -> VideoSearchResult? in
            let thumbnailString = failingThumbnails
                ? "https://thumbnails.preview.example/\(index).jpg"
                : solidThumbnails[index % solidThumbnails.count]
            guard
                let thumbnailURL = URL(string: thumbnailString),
                let sourceURL = URL(string: "https://www.youtube.com/watch?v=preview\(index)")
            else { return nil }
            return VideoSearchResult(thumbnailURL: thumbnailURL, sourceURL: sourceURL, title: titles[index], embedURL: nil)
        }
    }
}

#Preview("Vidéos — liste") {
    ScrollView {
        VideoResultsView(phase: .loaded(VideoResultsPreviewData.videos()), onSearch: {})
            .padding(20)
    }
}

#Preview("Vidéos — états") {
    GlassEffectContainer(spacing: 16) {
        VStack(alignment: .leading, spacing: 32) {
            VideoResultsView(phase: .idle, onSearch: {})
            VideoResultsView(phase: .loading, onSearch: {})
            VideoResultsView(phase: .loaded([]), onSearch: {})
            VideoResultsView(phase: .failed, onSearch: {})
        }
    }
    .padding(20)
}

#Preview("Vidéos — vignettes indisponibles, sombre") {
    ScrollView {
        VideoResultsView(phase: .loaded(VideoResultsPreviewData.videos(failingThumbnails: true)), onSearch: {})
            .padding(20)
    }
    .preferredColorScheme(.dark)
}

#Preview("Vidéos — très grand texte") {
    ScrollView {
        VideoResultsView(phase: .loaded(VideoResultsPreviewData.videos()), onSearch: {})
            .padding(20)
    }
    .dynamicTypeSize(.accessibility3)
}
