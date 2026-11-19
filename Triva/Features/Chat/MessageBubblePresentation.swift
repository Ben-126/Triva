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
        /// Mission E1a : une recherche a eu lieu, aucune source n'était lisible.
        var answeredWithoutReadableSource = false
        /// Mission A2 : aucune source n'a passé le test lexical de la chaîne (persisté, mission E2b).
        var sourcesMayBeOffTopic = false
        /// Mission C1 : SearXNG n'a pas répondu à cette recherche (persisté, mission E2b).
        var searXNGUnreachable = false
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
    /// demande, comme la version web d'origine) : sous une réponse terminée, ou arrêtée avec un
    /// texte, qui s'appuie sur des sources WEB. Écart assumé avec la version web d'origine, qui
    /// les montre sous chaque réponse : une salutation, un calcul ou une
    /// réponse tirée des seuls fichiers joints n'ont pas de sujet à illustrer,
    /// et deux boutons de plus sous chacune d'elles seraient du remplissage.
    /// Une recherche déjà lancée reste toujours visible.
    ///
    /// Masqués quand SearXNG n'a pas répondu à la recherche (décision de Ben, mission C1) :
    /// images et vidéos ne passent que par lui, les boutons échoueraient à coup sûr.
    static func showsMediaSearch(_ answer: AnswerSnapshot) -> Bool {
        if answer.isMediaSearchStarted { return true }
        guard !answer.searXNGUnreachable else { return false }
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

    /// Mission E1a : une recherche a eu lieu mais aucune source n'était lisible, la réponse vient de
    /// la mémoire du modèle. Même style que « Réponse sans recherche » : un constat, pas un avertissement.
    static let answerWithoutReadableSourceLabel = "Réponse sans source lisible"

    /// La mention à poser sous la réponse, `nil` si aucune.
    static func answerNote(_ answer: AnswerSnapshot) -> String? {
        guard showsAnswerWithoutSearch(answer) else { return nil }
        if answer.answeredOffline { return answerOfflineLabel }
        return answer.answeredWithoutReadableSource ? answerWithoutReadableSourceLabel : answerWithoutSearchLabel
    }

    /// Identifiant d'accessibilité de la mention (tests d'interface).
    static func answerNoteIdentifier(_ answer: AnswerSnapshot) -> String {
        if answer.answeredOffline { return "chat.answerOffline" }
        return answer.answeredWithoutReadableSource ? "chat.answerWithoutReadableSource" : "chat.answerWithoutSearch"
    }

    /// Décision 6 de Ben (mission A2) : aucune source n'a passé le test
    /// lexical, la chaîne a gardé la moins éloignée. « Probablement » : le
    /// test compare des mots, il ne lit pas le sens.
    static let offTopicSourcesLabel = "Sources probablement hors sujet"

    /// Sous un texte, pas sur une bulle vide ni sur l'état « Aucune source
    /// fiable » : la mention qualifie une réponse, il en faut une. Ni widget
    /// ni salutation : décidé en amont (`SearchArtifacts.answersWithoutSearch`).
    static func showsAnswerWithoutSearch(_ answer: AnswerSnapshot) -> Bool {
        (answer.answeredWithoutSearch || answer.answeredOffline || answer.answeredWithoutReadableSource)
            && answer.state != .noReliableSources
            && (answer.hasBody || answer.hasTLDR)
    }

    /// Avec au moins une source web affichée : sans elle, rien à qualifier.
    static func showsOffTopicSources(_ answer: AnswerSnapshot) -> Bool {
        answer.sourcesMayBeOffTopic && answer.webSourceCount > 0
    }
}
