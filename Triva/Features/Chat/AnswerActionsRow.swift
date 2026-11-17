//
//  AnswerActionsRow.swift
//  Triva
//
//  Copier et Partager sous une réponse terminée (mission C5, décision de Ben). Discrets, au style
//  du bouton favori (icône seule, encre secondaire, cible 44 pt sur iOS) ; libellés VoiceOver.
//  Le texte a déjà reçu la mention « générée par IA » (`AnswerShareText`).
//

import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

struct AnswerActionsRow: View {
    /// Texte déjà marqué (`AnswerShareText.text`).
    let text: String
    @State private var justCopied = false

    #if os(iOS)
    private static let minimumSide: CGFloat = 44
    #else
    private static let minimumSide: CGFloat = 28
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Button(action: copy) {
                Label(
                    justCopied ? AnswerShareText.copiedTitle : AnswerShareText.copyTitle,
                    systemImage: justCopied ? "checkmark" : "doc.on.doc"
                )
                .labelStyle(.iconOnly)
                .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.copyAnswer")

            ShareLink(item: text) {
                Label(AnswerShareText.shareTitle, systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.shareAnswer")
        }
        .foregroundStyle(.secondary)
        #if os(macOS)
        .help(AnswerShareText.copyTitle)
        #endif
    }

    private func copy() {
        #if os(iOS)
        // Un seul élément à deux représentations : le texte marqué (principal) et la métadonnée
        // « généré par IA » lisible par une machine (AI Act art. 50(2)).
        UIPasteboard.general.setItems([[
            UTType.utf8PlainText.identifier: text,
            AIProvenanceMetadata.pasteboardType: AIProvenanceMetadata.jsonData(),
        ]])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setData(
            AIProvenanceMetadata.jsonData(),
            forType: NSPasteboard.PasteboardType(AIProvenanceMetadata.pasteboardType)
        )
        #endif
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }
}
