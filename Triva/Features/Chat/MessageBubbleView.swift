import SwiftUI

// MARK: - Logique pure

/// Logique pure de `MessageBubbleView` : ce que la bulle montre, et le texte
/// qu'elle confie à `CitationView`.
///
/// Travaille sur des valeurs simples, jamais sur `ChatViewModel.Message` :
/// avec l'isolation par défaut du projet, `Message` est isolé au main actor,
/// et la suite de tests de cette logique (`MessageBubblePresentationTests`)
/// reste ainsi non isolée. Les types imbriqués portent `nonisolated`
/// eux-mêmes : ils n'héritent pas de celui de leur parent (même piège que
/// dans `CitationPresentation`).
///
/// ## Bug 13 de la revue (le Markdown modifiait les messages)
/// - Question : jamais de Markdown. `Text(verbatim:)`, et le libellé
///   VoiceOver est ce MÊME texte (`questionAccessibilityLabel`) : « Combien
///   font 12*3*2 ? » s'affiche et se lit tel quel.
/// - Réponse : Markdown interprété par `CitationView`, qui dérive son libellé
///   VoiceOver de sa propre valeur rendue (une seule source de vérité) : la
///   bulle ne le remplace plus par le texte brut, `**` et liens compris.
/// - Arithmétique d'une réponse (« 5*4*3 = 60 ») : voir
///   `protectingArithmetic(_:)` pour le compromis retenu.
nonisolated enum MessageBubblePresentation {

    // MARK: Textes

    static let questionAccessibilityPrefix = "Question"
    static let progressAccessibilityLabel = "Génération de la réponse en cours"

    // MARK: Révélation progressive pendant le streaming

    /// Pas de révélation du corps pendant le streaming, en caractères.
    ///
    /// Le fournisseur envoie un snapshot cumulatif par morceau de quelques
    /// caractères, et `CitationView` analyse TOUT le texte (citations, puis
    /// Markdown) et le remet en page à chaque valeur nouvelle : sur une longue
    /// réponse, le coût total croît comme le carré de la longueur. Le corps
    /// affiché n'avance donc que par paliers de 32 caractères (une demi-ligne
    /// d'iPhone, environ 8 morceaux) : l'analyse tourne environ 8 fois moins
    /// souvent, et `AnswerText` (`Equatable`) saute tous les snapshots qui ne
    /// changent pas le texte affiché.
    ///
    /// Plutôt qu'un minuteur (« au plus toutes les 60 ms ») : un minuteur
    /// garde un état et peut perdre le DERNIER morceau, ce qui ramènerait la
    /// réponse tronquée corrigée par 6ec621f. Ici, rien n'est retenu dès la
    /// fin du flux : le corps complet est affiché tel quel.
    static let streamingRevealStep = 32

    /// Le corps à confier à `CitationView`.
    ///
    /// - Hors streaming : le corps entier, toujours.
    /// - Pendant le streaming : le plus long préfixe d'au plus `n × step`
    ///   caractères (le plus grand multiple de `step` atteint), coupé au
    ///   DERNIER blanc qu'il contient — jamais un demi-mot à l'écran. Sans
    ///   aucun blanc (une longue URL), coupe nette au palier.
    ///
    /// Monotone : le texte affiché ne fait que grandir d'un snapshot au
    /// suivant (le corps ne grandit que par la fin, voir `ReasoningSegments`),
    /// donc rien ne disparaît puis ne revient à l'écran.
    static func displayedBody(_ body: String, isStreaming: Bool, revealStep: Int = streamingRevealStep) -> String {
        guard isStreaming, revealStep > 1 else { return body }
        let limit = (body.count / revealStep) * revealStep
        guard limit > 0 else { return "" }
        let prefix = body.prefix(limit)
        guard let lastBlank = prefix.lastIndex(where: \.isWhitespace) else { return String(prefix) }
        return String(prefix[..<lastBlank])
    }

    // MARK: Arithmétique

    /// Neutralise les `*` qui touchent un chiffre À L'INTÉRIEUR d'un mot :
    /// « 5*4*3 = 60 » restait « 543 = 60 » avec le 4 en italique, et
    /// « 2**10 » perdait ses astérisques.
    ///
    /// ## Compromis retenu (bug 13)
    /// Une suite de `*` est échappée (`\*`) quand ses DEUX voisins sont des
    /// lettres ou des chiffres et qu'AU MOINS UN est un chiffre ASCII :
    /// « 5*4 », « x*2*y », « 2**10 ». Tout le reste du Markdown est interprété
    /// comme avant : gras et italique d'un mot (« **Tokyo** »), et même
    /// l'emphase intra-mot entre lettres (« a*b*c »), trop rare dans une
    /// réponse pour justifier une règle de plus. Assumé aussi : `__init__.py`
    /// hors accents graves devient « init » en gras — un modèle met le code
    /// entre accents graves, et deviner un identifiant serait plus risqué
    /// que de l'accepter.
    ///
    /// Rien n'est touché entre accents graves (code) : `\*` y resterait
    /// affiché tel quel, CommonMark n'y traite pas les échappements. Un `\`
    /// déjà présent garde son caractère suivant tel quel.
    static func protectingArithmetic(_ markdown: String) -> String {
        let scalars = Array(markdown.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let end: Int
            switch scalars[index] {
            case "\\":
                end = min(index + 2, scalars.count)
                output.append(contentsOf: scalars[index..<end])
            case "`":
                end = codeSpanEnd(in: scalars, from: index)
                output.append(contentsOf: scalars[index..<end])
            case "*":
                end = runEnd(in: scalars, from: index)
                if touchesDigitInsideWord(scalars, runStart: index, runEnd: end) {
                    for _ in index..<end {
                        output.append(contentsOf: "\\*".unicodeScalars)
                    }
                } else {
                    output.append(contentsOf: scalars[index..<end])
                }
            default:
                end = index + 1
                output.append(scalars[index])
            }
            index = end
        }
        return String(output)
    }

    /// Fin d'une suite de caractères identiques à celui de `start`.
    private static func runEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < scalars.count, scalars[end] == scalars[start] {
            end += 1
        }
        return end
    }

    /// Règle CommonMark des passages de code : une suite de N accents graves
    /// s'ouvre et se referme sur la PROCHAINE suite d'exactement N. Sans
    /// fermeture, la suite d'ouverture n'est que du texte : seule elle est
    /// consommée, la suite est traitée normalement.
    private static func codeSpanEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        let openingEnd = runEnd(in: scalars, from: start)
        let length = openingEnd - start
        var cursor = openingEnd
        while cursor < scalars.count {
            guard scalars[cursor] == "`" else {
                cursor += 1
                continue
            }
            let closingEnd = runEnd(in: scalars, from: cursor)
            if closingEnd - cursor == length { return closingEnd }
            cursor = closingEnd
        }
        return openingEnd
    }

    private static func touchesDigitInsideWord(_ scalars: [Unicode.Scalar], runStart: Int, runEnd: Int) -> Bool {
        guard runStart > 0, runEnd < scalars.count else { return false }
        let before = scalars[runStart - 1]
        let after = scalars[runEnd]
        guard isWordCharacter(before), isWordCharacter(after) else { return false }
        return isASCIIDigit(before) || isASCIIDigit(after)
    }

    /// `0` à `9` (U+0030 à U+0039) seulement : un exposant « ² » n'est pas
    /// un opérande d'une multiplication écrite avec `*`.
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar) || scalar.properties.isAlphabetic
    }

    /// Le texte de réponse confié à `CitationView` : révélé par paliers
    /// pendant le streaming, puis protégé contre l'emphase arithmétique.
    static func answerText(_ body: String, isStreaming: Bool) -> String {
        protectingArithmetic(displayedBody(body, isStreaming: isStreaming))
    }

    // MARK: Accessibilité

    /// Libellé VoiceOver de la question : le rôle, puis EXACTEMENT le texte
    /// affiché, puis les fichiers joints. Jamais de Markdown interprété : ce
    /// qui est lu est ce qui est à l'écran.
    static func questionAccessibilityLabel(text: String, attachedFileNames: [String]) -> String {
        let question = "\(questionAccessibilityPrefix), \(text)"
        guard !attachedFileNames.isEmpty else { return question }
        // Pas de second point après « ? » ou « . » : la pause existe déjà.
        let endsSentence = text.last.map { sentenceEndings.contains($0) } ?? false
        let separator = endsSentence ? " " : ". "
        let heading = attachedFileNames.count == 1 ? "Fichier joint" : "Fichiers joints"
        return "\(question)\(separator)\(heading) : \(FileAttachmentPresentation.joinedFileNames(attachedFileNames))"
    }

    private static let sentenceEndings: Set<Character> = [".", "?", "!", "…"]

    // MARK: Favori

    static func favoriteTitle(isFavorite: Bool) -> String {
        isFavorite ? "Retirer des favoris" : "Ajouter aux favoris"
    }

    static func favoriteSymbolName(isFavorite: Bool) -> String {
        isFavorite ? "star.fill" : "star"
    }

    // MARK: Ce que montre une réponse

    /// Issue d'une réponse vue par la bulle : miroir de
    /// `ChatViewModel.Message.Status`, isolé au main actor, construit par la
    /// vue (`MessageBubbleView.answerSnapshot(of:)`).
    nonisolated enum AnswerState: Sendable, Equatable {
        case streaming
        case completed
        case failed
        case interrupted
        case noReliableSources
    }

    /// Ce que la bulle et ses voisines (médias, relance) ont besoin de savoir
    /// d'une réponse. Valeurs par défaut : une réponse vide.
    nonisolated struct AnswerSnapshot: Sendable, Equatable {
        var state: AnswerState
        var reasoningPhase: ReasoningPhase = .absent
        var hasTLDR = false
        /// Corps non vide (`ReasoningSegments.body`, déjà rogné).
        var hasBody = false
        var sourceCount = 0
        /// Sources web : toutes les sources moins les fichiers joints.
        var webSourceCount = 0
        /// Une recherche d'images ou de vidéos a déjà été lancée.
        var isMediaSearchStarted = false
        /// Service qui a fourni les sources web, `nil` sans recherche web ou
        /// pour un message relu (non persisté).
        var webSourceKind: WebSearchSourceKind?
        /// Mission A2 : rédigée sans recherche ni widget, hors salutation.
        var answeredWithoutSearch = false
        /// Tâche 1.16 : rédigée hors connexion, sans source ; remplace la mention précédente.
        var answeredOffline = false
        /// Mission A2 : aucune source n'a passé le test lexical de la chaîne.
        var sourcesMayBeOffTopic = false
    }

    /// Une bulle sans rien dedans (échec ou arrêt avant le moindre texte, la
    /// moindre source) n'est pas dessinée : un rectangle de verre vide ne dit
    /// rien, et le bandeau d'erreur de `ChatView` explique déjà l'échec. Le
    /// raisonnement compte : une réponse arrêtée pendant la réflexion garde
    /// son encadré.
    static func showsBubble(_ answer: AnswerSnapshot) -> Bool {
        answer.state == .streaming
            || answer.state == .noReliableSources
            || answer.reasoningPhase != .absent
            || answer.hasTLDR
            || answer.hasBody
            || answer.sourceCount > 0
    }

    /// L'indicateur d'attente tant que rien de lisible n'est arrivé. Pas
    /// pendant la réflexion : l'encadré de raisonnement montre déjà
    /// l'activité, et son aperçu défile.
    static func showsProgress(_ answer: AnswerSnapshot, displayedBodyIsEmpty: Bool) -> Bool {
        answer.state == .streaming
            && displayedBodyIsEmpty
            && !answer.hasTLDR
            && answer.reasoningPhase != .inProgress
    }

    /// Boutons « Rechercher des images / vidéos » (décision (a) : à la
    /// demande, comme le web) : sous une réponse terminée, ou arrêtée avec un
    /// texte, qui s'appuie sur des sources WEB. Écart assumé avec le web, qui
    /// les montre sous chaque réponse : une salutation, un calcul ou une
    /// réponse tirée des seuls fichiers joints n'ont pas de sujet à illustrer,
    /// et deux boutons de plus sous chacune d'elles seraient du remplissage.
    /// Une recherche déjà lancée reste toujours visible.
    static func showsMediaSearch(_ answer: AnswerSnapshot) -> Bool {
        if answer.isMediaSearchStarted { return true }
        let isSettled = answer.state == .completed || answer.state == .interrupted
        return isSettled && answer.hasBody && answer.webSourceCount > 0
    }

    /// La ligne discrète sous les sources (mission RI2) : d'où viennent les
    /// résultats, quand ce n'est pas SearXNG, le cas normal, qui n'a rien à
    /// signaler. Triva dit honnêtement quel service a répondu : l'utilisateur
    /// qui lit une réponse tirée de Wikipédia seule doit pouvoir le savoir.
    ///
    /// `webSourceCount`, pas `sourceCount` : la source est connue même quand
    /// elle a répondu à vide. Une réponse tirée des seuls fichiers joints n'a
    /// donc aucun résultat de ce service à annoncer.
    static func resultsOriginLabel(_ answer: AnswerSnapshot) -> String? {
        guard let kind = answer.webSourceKind, kind != .searxng, answer.webSourceCount > 0 else { return nil }
        return "Résultats\u{00A0}: \(kind.displayName)"
    }

    /// Décision 3 de Ben (mission A2) : une réponse rédigée sans aucune
    /// recherche le dit. Constat Q1 : « 330 pieds » pour la hauteur de la tour
    /// Eiffel, sans source, sans que rien ne signale l'absence de recherche.
    static let answerWithoutSearchLabel = "Réponse sans recherche"

    /// Tâche 1.16 (décision de Ben) : la même précision factuelle quand la cause est l'absence de
    /// connexion. Une seule mention à la fois : celle-ci l'emporte, elle dit aussi POURQUOI.
    static let answerOfflineLabel = "Hors connexion, sans source"

    /// La mention à poser sous la réponse, `nil` si aucune.
    static func answerNote(_ answer: AnswerSnapshot) -> String? {
        guard showsAnswerWithoutSearch(answer) else { return nil }
        return answer.answeredOffline ? answerOfflineLabel : answerWithoutSearchLabel
    }

    /// Décision 6 de Ben (mission A2) : aucune source n'a passé le test
    /// lexical, la chaîne a gardé la moins éloignée. « Probablement » : le
    /// test compare des mots, il ne lit pas le sens.
    static let offTopicSourcesLabel = "Sources probablement hors sujet"

    /// Sous un texte, pas sur une bulle vide ni sur l'état « Aucune source
    /// fiable » : la mention qualifie une réponse, il en faut une. Ni widget
    /// ni salutation : décidé en amont (`SearchArtifacts.answersWithoutSearch`).
    static func showsAnswerWithoutSearch(_ answer: AnswerSnapshot) -> Bool {
        (answer.answeredWithoutSearch || answer.answeredOffline)
            && answer.state != .noReliableSources
            && (answer.hasBody || answer.hasTLDR)
    }

    /// Avec au moins une source web affichée : sans elle, rien à qualifier.
    static func showsOffTopicSources(_ answer: AnswerSnapshot) -> Bool {
        answer.sourcesMayBeOffTopic && answer.webSourceCount > 0
    }
}

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
            sourcesMayBeOffTopic: message.sourcesMayBeOffTopic
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

/// La bulle d'une réponse. Quand il n'y a ni raisonnement, ni TL;DR, elle
/// est exactement ce qu'elle était : le texte, puis les sources.
private struct AnswerBubble: View {
    let message: ChatViewModel.Message
    let answer: MessageBubblePresentation.AnswerSnapshot
    let isFavorite: Bool
    let canToggleFavorite: Bool
    let onToggleFavorite: @MainActor () -> Void

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
                    isStreaming: message.isStreaming
                )
                .equatable()
                .font(.headline)
            }

            if answer.state == .noReliableSources {
                Text(ChatViewModel.noReliableSourcesMessage)
                    .foregroundStyle(.secondary)
            } else if MessageBubblePresentation.showsProgress(answer, displayedBodyIsEmpty: bodyText.isEmpty) {
                ProgressView()
                    .accessibilityLabel(MessageBubblePresentation.progressAccessibilityLabel)
                    .accessibilityIdentifier("chat.answerProgress")
            }

            if !bodyText.isEmpty {
                AnswerText(text: bodyText, sources: message.sources, isStreaming: message.isStreaming)
                    .equatable()
            }

            // Mission A2 : précision factuelle, rôle de la légende (DESIGN.md),
            // en `.secondary` plutôt que `.tertiary` : elle change la lecture
            // de la réponse, elle doit se voir.
            if let note = MessageBubblePresentation.answerNote(answer) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(answer.answeredOffline ? "chat.answerOffline" : "chat.answerWithoutSearch")
            }

            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SourcesListView(sources: message.sources)

                    if MessageBubblePresentation.showsOffTopicSources(answer) {
                        Text(MessageBubblePresentation.offTopicSourcesLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat.offTopicSources")
                    }

                    // Rôle de la légende de confidentialité (DESIGN.md) : une
                    // précision factuelle, sans verre ni icône.
                    if let origin = MessageBubblePresentation.resultsOriginLabel(answer) {
                        Text(origin)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if canToggleFavorite {
                FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
    let isStreaming: Bool

    var body: some View {
        CitationView(text: text, sources: sources, isStreaming: isStreaming)
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
