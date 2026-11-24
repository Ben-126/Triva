//
//  AttachmentQuickLook.swift
//  Triva
//
//  Chantier 2.2 (M5) : « Coup d'œil » (Quick Look) sur les pièces jointes, iPhone, iPad et Mac.
//  - capsule du composeur : menu contextuel partout, barre d'espace sur Mac ;
//  - source numérotée tirée d'une pièce jointe : même geste, sur la copie du coffre ;
//  - source web : Quick Look ne lit pas les pages, « Coup d'œil » ouvre le navigateur intégré (même libellé).
//  Le Coup d'œil n'existe que tant que la copie du fichier existe : jamais pour une conversation rouverte depuis
//  l'historique (on n'y garde que le texte extrait).
//

import QuickLook
import SwiftUI

nonisolated enum AttachmentQuickLookPresentation {
    static let menuTitle = "Coup d'œil"
    static let menuSystemImage = "eye"
}

/// Retrouve la copie d'une pièce jointe par son identifiant (celui de l'URL synthétique `triva-attachment:<UUID>`
/// d'une source). Fournie par le chat, qui possède le contrôleur de pièces jointes ; absente ailleurs (favoris :
/// aucune copie n'existe alors).
struct AttachmentFileLookup {
    var url: @MainActor (UUID) -> URL?
}

extension EnvironmentValues {
    @Entry var attachmentFileLookup: AttachmentFileLookup?
}

extension View {
    /// Coup d'œil sur une capsule de pièce jointe : menu contextuel, et barre d'espace sur Mac.
    func attachmentPreviewActions(canPreview: Bool, onPreview: @escaping () -> Void) -> some View {
        modifier(AttachmentPreviewActions(canPreview: canPreview, onPreview: onPreview))
    }

    /// Coup d'œil sur une ligne de la liste des sources (pièce jointe ou page web).
    func sourcePreviewAction(for source: SearXNGSearchResult) -> some View {
        modifier(SourcePreviewAction(source: source))
    }
}

private struct AttachmentPreviewActions: ViewModifier {
    let canPreview: Bool
    let onPreview: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if canPreview {
                    Button(AttachmentQuickLookPresentation.menuTitle, systemImage: AttachmentQuickLookPresentation.menuSystemImage, action: onPreview)
                }
            }
            #if os(macOS)
            // Barre d'espace sur la capsule sélectionnée, comme dans le Finder.
            .focusable(canPreview)
            .onKeyPress(.space) {
                guard canPreview else { return .ignored }
                onPreview()
                return .handled
            }
            #endif
    }
}

private struct SourcePreviewAction: ViewModifier {
    let source: SearXNGSearchResult
    @Environment(\.attachmentFileLookup) private var fileLookup
    @Environment(\.openURL) private var openURL
    @State private var previewedURL: URL?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let attachmentID = UploadsSearchResultBuilder.attachmentID(fromSourceURL: source.url) {
                    if let fileURL = fileLookup?.url(attachmentID) {
                        previewButton { previewedURL = fileURL }
                    }
                } else if let webURL = SourcesListPresentation.openableURL(for: source) {
                    previewButton { openURL(webURL) }
                }
            }
            .quickLookPreview($previewedURL)
            // « Tout effacer » : l'aperçu se ferme avant que son fichier ne soit supprimé.
            .onReceive(NotificationCenter.default.publisher(for: AttachmentVaultPurgeSignal.notificationName)) { _ in
                previewedURL = nil
            }
    }

    private func previewButton(action: @escaping () -> Void) -> some View {
        Button(AttachmentQuickLookPresentation.menuTitle, systemImage: AttachmentQuickLookPresentation.menuSystemImage, action: action)
    }
}
