import SwiftUI

// MARK: - Vue

/// Une bulle du fil de chat. Apparence selon `role` :
/// - `.user` : hugue son contenu, poussée à droite (`Spacer` à gauche), verre
///   teinté à l'accent (même principe que la carte sélectionnée de
///   DESIGN.md : une teinte, pas de bordure). Texte VERBATIM, fichiers joints
///   en dessous.
/// - `.assistant` : toute la largeur, verre neutre. De haut en bas :
///   raisonnement (`ThinkBoxView`), TL;DR du mode Approfondi, corps avec
///   citations cliquables (`CitationView`), sources, étoile de favori.
///
/// Les widgets (au-dessus), les médias et le bouton « Relancer en mode
/// Rapide » (en dessous) ne sont PAS dans la bulle : ce sont des éléments en
/// verre, et du verre sur du verre est exclu (DESIGN.md, Liquid Glass). C'est
/// `ChatView` qui les pose, en frères dans le même `GlassEffectContainer`.
///
/// Un seul rayon de coin : `.rect(cornerRadius: 20)` (DESIGN.md).
///
/// ## `Equatable` écrit à la main
/// `ChatView` applique `.equatable()` à chaque bulle : `ChatViewModel` est
/// `@Observable` au niveau de la PROPRIÉTÉ, chaque snapshot de streaming
/// invalide tout `messages`, et sans ce garde-fou le corps des N-1 bulles
/// inchangées serait réévalué à chaque morceau reçu. La comparaison porte sur
/// `message` et les deux états du favori ; `onToggleFavorite` est ignorée :
/// elle ne capture que l'identifiant du message et le ViewModel, stables pour
/// une même bulle.
struct MessageBubbleView: View, Equatable {
    let message: ChatViewModel.Message
    /// Étoile pleine. Calculé par `ChatView` DANS son `body` : la lecture
    /// observe `FavoritesStore.revision`, l'étoile suit donc un favori changé
    /// depuis une autre fenêtre (iPad, Mac).
    var isFavorite = false
    /// Réponse terminée et enregistrée (`ChatViewModel.canToggleFavorite`) :
    /// sans cela, pas d'étoile du tout.
    var canToggleFavorite = false
    var onToggleFavorite: @MainActor () -> Void = {}

    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message
            && lhs.isFavorite == rhs.isFavorite
            && lhs.canToggleFavorite == rhs.canToggleFavorite
    }

    var body: some View {
        switch message.role {
        case .user:
            QuestionBubble(text: message.text, attachedFiles: message.attachedFiles)
        case .assistant:
            let answer = Self.answerSnapshot(of: message)
            if MessageBubblePresentation.showsBubble(answer) {
                AnswerBubble(
                    message: message,
                    answer: answer,
                    isFavorite: isFavorite,
                    canToggleFavorite: canToggleFavorite,
                    onToggleFavorite: onToggleFavorite
                )
            }
        }
    }

    /// Le résumé pur d'une réponse, pour la bulle et pour `ChatView` (médias).
    static func answerSnapshot(of message: ChatViewModel.Message) -> MessageBubblePresentation.AnswerSnapshot {
        MessageBubblePresentation.AnswerSnapshot(
            state: answerState(of: message.status),
            reasoningPhase: message.segments.reasoningPhase,
            hasTLDR: message.segments.tldr != nil,
            hasBody: !message.segments.body.isEmpty,
            sourceCount: message.sources.count,
            webSourceCount: max(0, message.sources.count - message.attachmentSourceCount),
            isMediaSearchStarted: !isIdle(message.images) || !isIdle(message.videos),
            webSourceKind: message.webSourceKind,
            answeredWithoutSearch: message.answeredWithoutSearch,
            answeredOffline: message.answeredOffline,
            answeredWithoutReadableSource: message.answeredWithoutReadableSource,
            sourcesMayBeOffTopic: message.sourcesMayBeOffTopic,
            searXNGUnreachable: message.searXNGUnreachable
        )
    }

    private static func answerState(of status: ChatViewModel.Message.Status) -> MessageBubblePresentation.AnswerState {
        switch status {
        case .streaming: .streaming
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .interrupted
        case .noReliableSources: .noReliableSources
        }
    }

    private static func isIdle(_ phase: ImageResultsPhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    private static func isIdle(_ phase: VideoResultsPhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }
}

// MARK: - Question

/// La question, telle que tapée : `Text(verbatim:)`, jamais de Markdown
/// (« __init__.py » ou « 12*3*2 » restent intacts). Un seul élément
/// VoiceOver, en-tête : le rotor « En-têtes » saute de question en question
/// dans une longue conversation.
private struct QuestionBubble: View {
    let text: String
    let attachedFiles: [ChatViewModel.Message.AttachedFile]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: text)

                if !attachedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(attachedFiles) { file in
                            Label(shortName(of: file), systemImage: FileAttachmentPresentation.symbolName(for: file.kind))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(MessageBubblePresentation.questionAccessibilityLabel(
                text: text,
                attachedFileNames: attachedFiles.map(\.fileName)
            ))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chat.question")
        }
    }

    /// Même raccourcissement que les capsules de `FileAttachmentTray` : le
    /// nom complet reste dans le libellé VoiceOver.
    private func shortName(of file: ChatViewModel.Message.AttachedFile) -> String {
        FileAttachmentPresentation.shortenedName(
            FileAttachmentPresentation.displayName(for: file.fileName),
            maxLength: FileAttachmentPresentation.maxNameLength(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        )
    }
}

// MARK: - Réponse

extension MessageBubbleView {
    /// Encre des légendes posées sur le verre de la réponse : voir `AnswerBubble.legendStyle`.
    static let legendStyle = Color.primary.opacity(0.8)
}

/// La bulle d'une réponse. Quand il n'y a ni raisonnement, ni TL;DR, elle
/// est exactement ce qu'elle était : le texte, puis les sources.
private struct AnswerBubble: View {
    let message: ChatViewModel.Message
    let answer: MessageBubblePresentation.AnswerSnapshot
    let isFavorite: Bool
    let canToggleFavorite: Bool
    let onToggleFavorite: @MainActor () -> Void

    /// Position de lecture de la session (aussi porteuse de la réponse ciblée par le volet de sources) : lecture
    /// OPTIONNELLE, les aperçus n'en injectent pas.
    @Environment(TranscriptScrollState.self) private var transcriptState: TranscriptScrollState?
    @Environment(\.sourcesShownInPane) private var sourcesShownInPane

    /// Une citation touchée cible CETTE réponse dans le volet de sources (Duo déplié). `nil` sans état de session.
    private var focusThisAnswer: (@MainActor () -> Void)? {
        guard let transcriptState else { return nil }
        let messageID = message.id
        return { transcriptState.focusedAnswerID = messageID }
    }

    /// Légendes sous la réponse (« Réponse sans recherche », « Sources probablement hors
    /// sujet », origine des résultats, étape de génération). En `.secondary`, elles mesuraient
    /// 2,88:1 sur le verre en clair (QA Q3, finding 8) ; décision de Ben (2026-11-11) : plus
    /// foncées, pour atteindre 4,5:1 sur le verre en clair ET en sombre. Le primaire du système à
    /// 80 % garde une hiérarchie visible avec le corps tout en passant le seuil (mesuré sur
    /// capture, mission C1). Couleur sémantique : elle suit le mode sombre et « Augmenter le
    /// contraste ». Définie sur `MessageBubbleView` pour être partagée avec le domaine des
    /// sources (`SourcesListView`), affiché sur le même verre.
    private static let legendStyle = MessageBubbleView.legendStyle

    var body: some View {
        let segments = message.segments
        let bodyText = MessageBubblePresentation.answerText(segments.body, isStreaming: message.isStreaming)

        VStack(alignment: .leading, spacing: 12) {
            if segments.hasReasoning {
                ThinkBoxView(segments: segments, timing: message.reasoningTiming)
            }

            if let tldr = segments.tldr {
                // Une phrase qui répond tout de suite : en tête, en gras
                // sémantique (`.headline`), avec ses citations cliquables.
                AnswerText(
                    text: MessageBubblePresentation.protectingArithmetic(tldr),
                    sources: message.sources,
                    unreadNumbers: message.uncitableSourceNumbers,
                    isStreaming: message.isStreaming,
                    onCitationSelected: focusThisAnswer
                )
                .equatable()
                .font(.headline)
            }

            if answer.state == .noReliableSources {
                // `.primary` (QA Q3, finding 8) : c'est tout le contenu de la réponse, pas un état
                // désactivé ; en `.secondary`, il mesurait 2,88:1 sur le verre.
                Text(ChatViewModel.noReliableSourcesMessage)
                    .accessibilityIdentifier("chat.noReliableSources")
            } else if MessageBubblePresentation.showsProgress(answer, displayedBodyIsEmpty: bodyText.isEmpty) {
                // Ligne d'état discrète (finding 31) : ce que l'app fait pendant l'attente.
                HStack(spacing: 8) {
                    ProgressView()
                        .accessibilityIdentifier("chat.answerProgress")
                    Text(message.generationStage.statusText)
                        .font(.footnote)
                        .foregroundStyle(Self.legendStyle)
                        .accessibilityIdentifier("chat.generationStage")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message.generationStage.statusText)
            }

            if !bodyText.isEmpty {
                AnswerText(
                    text: bodyText,
                    sources: message.sources,
                    unreadNumbers: message.uncitableSourceNumbers,
                    isStreaming: message.isStreaming,
                    onCitationSelected: focusThisAnswer
                )
                .equatable()
            }

            // Mission A2 : précision factuelle ; même composant que le détail d'un favori (E2b).
            AnswerNoteLine(answer: answer)

            // Avertissement permanent « généré par IA » (mission C3, audit légal constat 9).
            if AIDisclaimerPolicy.shows(state: answer.state, hasText: !bodyText.isEmpty) {
                AIDisclaimerLine()
            }

            // Duo déplié : la liste vit dans le volet de droite (`SearchSourcesPane`), pas dans la bulle.
            if !message.sources.isEmpty, !sourcesShownInPane {
                AnswerSourcesSection(message: message, answer: answer)
            }

            // Copier / Partager (mission C5) : texte marqué « généré par IA », réponse terminée seulement.
            let shareText = AnswerShareText.isOffered(state: answer.state, hasText: segments.tldr != nil || !segments.body.isEmpty)
                ? AnswerShareText.text(tldr: segments.tldr, body: segments.body, sources: message.sources)
                : nil
            if canToggleFavorite || shareText != nil {
                HStack(spacing: 0) {
                    if let shareText {
                        AnswerActionsRow(text: shareText)
                    }
                    Spacer(minLength: 0)
                    if canToggleFavorite {
                        FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// `CitationView` n'est pas `Equatable` : ce relais l'est, pour que
/// `.equatable()` saute l'analyse (citations, Markdown, libellé VoiceOver)
/// tant que le texte affiché ne change pas — le cas de la plupart des
/// snapshots, voir `MessageBubblePresentation.displayedBody`.
private struct AnswerText: View, Equatable {
    let text: String
    let sources: [SearXNGSearchResult]
    var unreadNumbers: Set<Int> = []
    let isStreaming: Bool
    /// Appelée quand une citation est touchée (mission I2). Ignorée par `==` : elle ne capture que la session
    /// et l'identifiant du message, stables pour une même bulle (même raison que `onToggleFavorite`).
    var onCitationSelected: (@MainActor () -> Void)?

    static func == (lhs: AnswerText, rhs: AnswerText) -> Bool {
        lhs.text == rhs.text && lhs.sources == rhs.sources
            && lhs.unreadNumbers == rhs.unreadNumbers && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        CitationView(
            text: text, sources: sources, isStreaming: isStreaming,
            unreadSourceNumbers: unreadNumbers, onCitationSelected: onCitationSelected
        )
    }
}

/// Étoile de favori, dans la bulle : style `.plain` et non `.glass`, la bulle
/// étant déjà en verre. Icône seule à l'écran, titre complet pour VoiceOver
/// et l'infobulle macOS. Cible de 44 pt sur iOS (HIG), 28 pt sur Mac.
private struct FavoriteButton: View {
    let isFavorite: Bool
    let action: @MainActor () -> Void

    #if os(iOS)
    private static let minimumSide: CGFloat = 44
    #else
    private static let minimumSide: CGFloat = 28
    #endif

    var body: some View {
        let title = MessageBubblePresentation.favoriteTitle(isFavorite: isFavorite)
        Button(action: action) {
            Label(title, systemImage: MessageBubblePresentation.favoriteSymbolName(isFavorite: isFavorite))
                .labelStyle(.iconOnly)
                .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .accessibilityIdentifier("chat.favorite")
        #if os(macOS)
        .help(title)
        #endif
    }
}

// MARK: - Previews

private let previewSources: [SearXNGSearchResult] = [
    SearXNGSearchResult(
        title: "Tokyo — Wikipédia",
        url: "https://fr.wikipedia.org/wiki/Tokyo",
        content: "Tokyo est la capitale du Japon depuis 1868.",
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    ),
    SearXNGSearchResult(
        title: "Documentation Swift Concurrency",
        url: "https://developer.apple.com/documentation/swift/concurrency",
        content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    ),
]

#Preview("Question — texte intact") {
    MessageBubbleView(message: .init(role: .user, text: "Combien font 12*3*2 ? Et que fait __init__.py ?"))
        .padding(20)
}

#Preview("Question — fichiers joints") {
    var message = ChatViewModel.Message(role: .user, text: "Résume ces deux documents.")
    message.attachedFiles = [
        .init(id: UUID(), fileName: "rapport-annuel-2026-version-relue.pdf", kind: .pdf),
        .init(id: UUID(), fileName: "notes.md", kind: .markdown),
    ]
    return MessageBubbleView(message: message)
        .padding(20)
}

#Preview("Réponse — en streaming, sans texte") {
    MessageBubbleView(message: .init(role: .assistant, text: "", isStreaming: true))
        .padding(20)
}

#Preview("Réponse — citations et favori") {
    MessageBubbleView(
        message: .init(
            role: .assistant,
            text: "La capitale du Japon est **Tokyo**[1]. On y compte 5*4*3 = 60 arrondissements fictifs.",
            sources: previewSources
        ),
        isFavorite: true,
        canToggleFavorite: true
    )
    .padding(20)
}

#Preview("Réponse — raisonnement et TL;DR, sombre") {
    MessageBubbleView(message: .init(
        role: .assistant,
        text: "<think>La question porte sur la capitale. La source 1 le confirme.</think><tldr>Tokyo est la capitale du Japon[1].</tldr>Tokyo est la capitale du Japon depuis 1868[1].",
        sources: previewSources
    ))
    .padding(20)
    .preferredColorScheme(.dark)
}

#Preview("Réponse — résultats d'une source de secours") {
    var message = ChatViewModel.Message(
        role: .assistant,
        text: "La capitale du Japon est **Tokyo**[1].",
        sources: previewSources
    )
    message.webSourceKind = .wikipedia
    return MessageBubbleView(message: message)
        .padding(20)
}

#Preview("Réponse — sans recherche") {
    var message = ChatViewModel.Message(
        role: .assistant,
        text: "Feuilles rousses au vent,\nle ciel bas se tait,\nl'automne s'installe."
    )
    message.answeredWithoutSearch = true
    return MessageBubbleView(message: message)
        .padding(20)
}

#Preview("Réponse — hors connexion") {
    var message = ChatViewModel.Message(
        role: .assistant,
        text: "Canberra est la capitale de l'Australie."
    )
    message.answeredOffline = true
    return MessageBubbleView(message: message)
        .padding(20)
}

#Preview("Réponse — sources probablement hors sujet, sombre") {
    var message = ChatViewModel.Message(
        role: .assistant,
        text: PromptTemplates.noRelevantInformationAnswer,
        sources: previewSources
    )
    message.webSourceKind = .wikipedia
    message.sourcesMayBeOffTopic = true
    return MessageBubbleView(message: message)
        .padding(20)
        .preferredColorScheme(.dark)
}

#Preview("Réponse — aucune source fiable") {
    var message = ChatViewModel.Message(role: .assistant, isStreaming: true)
    message.markNoReliableSources(searchQuery: "Faut-il préférer les tabs aux espaces ?", at: .now)
    return MessageBubbleView(message: message)
        .padding(20)
}
