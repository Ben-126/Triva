//
//  AnswerNoteViews.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Les deux petites mentions d'une réponse, partagées par la bulle du chat et le détail d'un
/// favori (mission E2b, décision de Ben) : un seul composant, donc un seul texte, une seule
/// police et une seule encre des deux côtés. Le « quand » reste dans `MessageBubblePresentation`
/// (`answerNote`, `showsOffTopicSources`), qui lit un `AnswerSnapshot`.

/// « Réponse sans recherche », « Hors connexion, sans source » ou « Réponse sans source lisible »,
/// sous le texte de la réponse. Rien ne s'affiche quand aucune mention n'est due.
///
/// Précision factuelle, rôle de la légende (DESIGN.md) : elle change la lecture de la réponse,
/// elle doit se voir (`MessageBubbleView.legendStyle`).
struct AnswerNoteLine: View {
    let answer: MessageBubblePresentation.AnswerSnapshot

    var body: some View {
        if let note = MessageBubblePresentation.answerNote(answer) {
            Text(note)
                .font(.caption)
                .foregroundStyle(MessageBubbleView.legendStyle)
                .accessibilityIdentifier(MessageBubblePresentation.answerNoteIdentifier(answer))
        }
    }
}

/// « Sources probablement hors sujet », sous la liste des sources.
struct OffTopicSourcesNote: View {
    let answer: MessageBubblePresentation.AnswerSnapshot

    var body: some View {
        if MessageBubblePresentation.showsOffTopicSources(answer) {
            Text(MessageBubblePresentation.offTopicSourcesLabel)
                .font(.caption)
                .foregroundStyle(MessageBubbleView.legendStyle)
                .accessibilityIdentifier("chat.offTopicSources")
        }
    }
}
