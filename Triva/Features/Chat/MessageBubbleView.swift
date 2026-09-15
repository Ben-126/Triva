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
///
/// `Equatable` (synthétisée à partir de `message`, seule propriété stockée) :
/// permet à `ChatView.messagesList` d'appliquer `.equatable()` sur chaque
/// bulle. `ChatViewModel` est `@Observable` au niveau de la PROPRIÉTÉ, donc
/// chaque snapshot de streaming (`messages[index].text = snapshot`) invalide
/// tout `messages` — sans `.equatable()`, le `ForEach` re-évaluerait le corps
/// des N-1 bulles dont le contenu n'a pas changé à chaque token reçu.
struct MessageBubbleView: View, Equatable {
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
                    Text(Self.attributedText(from: message.text))
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

    /// `Text(String)` n'interprète jamais le Markdown à l'exécution (seuls les
    /// littéraux `LocalizedStringKey` connus à la compilation en bénéficient)
    /// — c'était le bug : une réponse contenant `**Duo Mobile**` s'affichait
    /// avec les astérisques au lieu du gras. `AttributedString(markdown:)` le
    /// parse au runtime. `.inlineOnlyPreservingWhitespace` se limite au gras/
    /// italique/code/liens/barré et préserve les retours à la ligne, sans
    /// réinterpréter la réponse en blocs structurés (titres, listes à puces
    /// avec mise en page propre) que `Text` ne rend de toute façon pas bien.
    private static func attributedText(from text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
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
