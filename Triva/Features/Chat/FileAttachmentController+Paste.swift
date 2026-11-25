//
//  FileAttachmentController+Paste.swift
//  Triva
//
//  K2 : « Coller » (menu du trombone sur iPhone, iPad et iPhone Duo) et collage de la fenêtre Mac. La DÉCISION (texte
//  normal ou pièce jointe) est `PasteboardClassifier` ; ici seulement la lecture du presse-papiers et l'application.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension FileAttachmentController {
    /// Applique des éléments COLLÉS : fichiers et images joints, refus expliqués. Le texte et les adresses web
    /// appartiennent au champ de saisie (collage normal, jamais coupé) : ils ne passent pas par le plan du dépôt.
    func receivePasted(_ items: [DroppedItem]) {
        let attachable = DropPlan.attachableOnly(items)
        guard !attachable.isEmpty else { return }
        receive(DropPlan(items: attachable))
    }

    /// Ajoute du texte collé au brouillon, tel quel (comme le champ le ferait).
    static func appendPastedText(_ text: String, to draft: inout String) {
        draft = DropPlan.appending([text], to: draft)
    }
}

#if os(iOS)
extension FileAttachmentController {
    /// Entrée « Coller » du menu du trombone. Lire le presse-papiers d'une autre app déclenche l'alerte système
    /// « Autoriser le collage » (iOS 16+) : normal, c'est un geste explicite de l'utilisateur.
    func pasteFromClipboard(draft: Binding<String>) async {
        let providers = UIPasteboard.general.itemProviders
        let snapshot = await Self.snapshot(of: providers)
        switch PasteboardClassifier.decision(for: snapshot) {
        case .files, .image:
            let attachable = providers.filter(Self.isFileOrImage)
            receivePasted(await PasteImport.items(from: attachable))
        case .text:
            if let text = snapshot.text { Self.appendPastedText(text, to: &draft.wrappedValue) }
        case .nothing:
            reportInformation(FileAttachmentPresentation.nothingToPasteMessage)
        }
    }

    private static func isFileOrImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || PastedImageFormat.best(among: provider.registeredTypeIdentifiers) != nil
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    private static func snapshot(of providers: [NSItemProvider]) async -> PasteboardSnapshot {
        var snapshot = PasteboardSnapshot()
        snapshot.hasFileItem = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        snapshot.hasImage = providers.contains {
            PastedImageFormat.best(among: $0.registeredTypeIdentifiers) != nil || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        for provider in providers where provider.canLoadObject(ofClass: String.self) {
            if let text = await loadString(from: provider) {
                snapshot.text = text
                break
            }
        }
        return snapshot
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                continuation.resume(returning: string)
            }
        }
    }
}
#endif
