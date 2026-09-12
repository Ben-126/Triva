import SwiftUI

/// Une bulle de message du fil de chat (0.8, 3e étape). Apparence différente
/// selon `role` :
/// - `.user` : hugue son contenu, poussée à droite (`Spacer` côté gauche),
///   verre teinté à l'accent — même principe que la carte sélectionnée dans
///   DESIGN.md (teinte plutôt que bordure `.stroke` pour indiquer un état).
/// - `.assistant` : occupe toute la largeur disponible, verre neutre, avec
///   sous le texte la liste des sources (`SourcesListView`) si le message en
///   a — même style que `resultSection` de l'ancienne `SearchTestSection`
///   (`ContentView.swift`, test 0.7) avant son remplacement par cette vue.
///
/// Utilise exclusivement `.rect(cornerRadius: 20)` (DESIGN.md : un seul rayon
/// de coin pour les conteneurs de cette taille).
struct MessageBubbleView: View {
    let message: ChatViewModel.Message

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            bubbleContent
                .padding(16)
                .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
                .glassEffect(glass, in: .rect(cornerRadius: 20))
        }
    }

    private var accessibilityLabel: String {
        let roleLabel = message.role == .user ? "Vous" : "Assistant"
        if message.isStreaming && message.text.isEmpty {
            return "\(roleLabel), génération de la réponse en cours"
        }
        return "\(roleLabel), \(message.text)"
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sans ceci, VoiceOver ne communique le rôle (utilisateur/
            // assistant) que visuellement (alignement + teinte du verre).
            // Combine + `accessibilityLabel` ne portent QUE sur le texte/
            // `ProgressView` — jamais sur `SourcesListView` juste en dessous,
            // qui doit rester EN DEHORS de cet élément combiné : chaque
            // source y est son propre `Link` individuellement balayable
            // (trait `.isLink`, voir `SourcesListView`) ; les fusionner ici
            // les rendrait inatteignables un par un pour VoiceOver.
            Group {
                if message.isStreaming && message.text.isEmpty {
                    ProgressView()
                        .accessibilityLabel("Génération de la réponse en cours")
                } else {
                    Text(message.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)

            if message.role == .assistant, !message.sources.isEmpty {
                SourcesListView(sources: message.sources)
            }
        }
    }

    private var glass: Glass {
        message.role == .user ? .regular.tint(.accentColor.opacity(0.12)) : .regular
    }
}

#Preview("Utilisateur") {
    MessageBubbleView(message: .init(role: .user, text: "Résume l'actualité tech d'aujourd'hui."))
        .padding(20)
}

#Preview("Assistant — en streaming, sans texte") {
    MessageBubbleView(message: .init(role: .assistant, text: "", isStreaming: true))
        .padding(20)
}

#Preview("Assistant — avec sources") {
    MessageBubbleView(message: .init(
        role: .assistant,
        text: "Voici un résumé basé sur plusieurs sources récentes.",
        sources: [
            SearXNGSearchResult(
                title: "Documentation Swift Concurrency",
                url: "https://developer.apple.com/documentation/swift/concurrency",
                content: nil,
                imgSrc: nil,
                thumbnailSrc: nil,
                thumbnail: nil,
                author: nil,
                iframeSrc: nil
            ),
        ]
    ))
    .padding(20)
}

#Preview("Assistant — sans sources, sombre") {
    MessageBubbleView(message: .init(role: .assistant, text: "Réponse sans recherche associée."))
        .padding(20)
        .preferredColorScheme(.dark)
}
