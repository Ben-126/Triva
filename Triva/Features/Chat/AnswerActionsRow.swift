//
//  AnswerActionsRow.swift
//  Triva
//
//  Copier et Partager sous une réponse terminée (mission C5, décision de Ben). Discrets, au style
//  du bouton favori (icône seule, encre secondaire, cible 44 pt sur iOS) ; libellés VoiceOver.
//  Le texte a déjà reçu la mention « générée par IA » (`AnswerShareText`). Mac et iPad : une poignée de
//  glisser (`AnswerDragHandle`) emporte ce même texte vers une autre app.
//

import SwiftUI

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
            #if os(macOS)
            .help(justCopied ? AnswerShareText.copiedTitle : AnswerShareText.copyTitle)
            #endif

            ShareLink(item: text) {
                Label(AnswerShareText.shareTitle, systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.shareAnswer")
            #if os(macOS)
            .help(AnswerShareText.shareTitle)
            #endif

            // Glisser vers une autre app (Mac, iPad) : même texte marqué que Copier et Partager (mission G2).
            AnswerDragHandle(text: text)
        }
        .foregroundStyle(.secondary)
        // Pas de `.help` ici : sur Mac, une infobulle posée sur le conteneur est héritée par TOUS ses boutons
        // (aide d'accessibilité « Copier la réponse » sur Partager et Glisser, constaté le 24/11, mission F4).
        // Chaque bouton porte la sienne.
    }

    private func copy() {
        AnswerPasteboard.copy(text)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }
}
