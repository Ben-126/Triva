//
//  ReasoningSegmenter.swift
//  Triva
//
//  Created by ben podrojsky on 30/09/2026.
//

import Foundation

// MARK: - Phase du raisonnement

/// Où en est le raisonnement visible (bloc `<think>`) d'une réponse, pour UN
/// instantané de son texte.
///
/// C'est l'état que la tâche 1.14 demande d'exposer explicitement. Le web n'a
/// qu'un booléen `thinkingEnded` (`src/lib/hooks/useChat.tsx`), vrai dès
/// qu'un `</think>` apparaît dans le texte. Un booléen ne suffit pas ici :
/// - il ne distingue pas « aucun raisonnement » de « raisonnement pas encore
///   terminé ». Or l'absence de `<think>` est le cas NORMAL : Apple
///   Intelligence, modes Rapide et Fiable, petits modèles ;
/// - il ne sait pas dire « le flux s'est arrêté avant `</think>` ». Dans ce
///   cas le web affiche « Thinking… » indéfiniment.
///
/// ## Contrat pour la vue (ThinkBoxView)
///
/// - `absent` : aucun encadré.
/// - `inProgress` : encadré DÉPLIÉ, libellé « Raisonnement… » animé, contenu
///   partiel qui grossit.
/// - `completed` : encadré REPLIÉ automatiquement, une seule fois, au moment
///   de la transition. L'utilisateur peut le rouvrir.
/// - `interrupted` : encadré DÉPLIÉ, sans animation, JAMAIS replié
///   automatiquement. Le texte du bloc peut être le seul texte de la
///   réponse : c'est le mode de défaillance documenté par
///   `ResponseStructureViolation.Kind.unclosedReasoningBlock` (un petit
///   modèle ouvre `<think>` et n'écrit jamais `</think>`). S'y ajoutent la
///   limite de tokens et l'arrêt par l'utilisateur en pleine réflexion. Le
///   replier cacherait tout.
///
/// ## Garantie anti-clignotement
///
/// Pendant un stream (`isStreaming == true`), la phase ne fait QUE progresser
/// dans l'ordre `absent → inProgress → completed`. Une étape peut être
/// sautée, jamais défaite. `interrupted` n'apparaît qu'une fois le flux
/// terminé. Deux règles de `ReasoningSegmenter` rendent cette garantie
/// possible :
/// - un bloc VIDE ne compte pas. Le `<think>\n\n</think>` que Qwen3 émet en
///   mode non-thinking reste `absent` d'un bout à l'autre : l'encadré
///   n'apparaît jamais pour disparaître aussitôt ;
/// - une fois un bloc terminé, la phase reste `completed`, même si un second
///   bloc s'ouvre ensuite (voir « Plusieurs blocs » sur `ReasoningSegmenter`).
///
/// `CaseIterable` sert aux `#Preview` de la vue, qui doivent montrer chacune
/// des quatre phases.
nonisolated enum ReasoningPhase: Sendable, Equatable, CaseIterable {
    /// Aucun raisonnement à montrer. Jamais une erreur, voir le type.
    case absent
    /// Un bloc `<think>` est ouvert et contient déjà du texte ; `</think>`
    /// n'est pas encore arrivé et le flux continue.
    case inProgress
    /// Au moins un bloc s'est refermé avec du contenu.
    case completed
    /// Le flux s'est terminé alors qu'un bloc, le seul à avoir du contenu,
    /// était encore ouvert.
    case interrupted
}

// MARK: - Résultat

/// Les trois parties d'une réponse : raisonnement, TL;DR, corps.
///
/// Chaque partie est débarrassée de ses balises puis rognée (blancs de tête et
/// de queue). Invariants vérifiés par les tests :
/// - `reasoningPhase == .absent` ⟺ `reasoning.isEmpty`. La vue n'a donc
///   jamais à gérer un encadré vide, ni du raisonnement sans encadré ;
/// - `tldr` vaut `nil` plutôt qu'une chaîne vide. Un `<tldr></tldr>`, ou un
///   `<tldr>` qui vient de s'ouvrir, ne fait pas apparaître une carte vide ;
/// - d'un instantané de stream au suivant, chaque partie ne fait que grandir
///   par la fin : la précédente est un préfixe de la suivante. Une seule
///   exception, documentée sur `ReasoningSegmenter` : le `</think>` orphelin.
///
/// `body` est ce que la vue passe ensuite à `CitationParser.parse` (tâche
/// 1.12). Le segmenteur ne touche jamais aux crochets `[n]`, ni dans le corps
/// ni dans le raisonnement.
nonisolated struct ReasoningSegments: Sendable, Equatable {
    /// Texte du raisonnement, sans les balises. Plusieurs blocs sont joints
    /// par une ligne vide.
    let reasoning: String
    let reasoningPhase: ReasoningPhase
    /// Le TL;DR d'une phrase du mode Approfondi, ou `nil` s'il est absent ou
    /// vide.
    let tldr: String?
    /// Le corps de la réponse, sans raisonnement ni TL;DR.
    let body: String

    /// Raccourci pour la vue : y a-t-il un encadré de raisonnement à afficher ?
    var hasReasoning: Bool {
        reasoningPhase != .absent
    }
}

// MARK: - Segmenteur

/// Sépare une réponse générée en raisonnement (`<think>…</think>`), TL;DR
/// (`<tldr>…</tldr>`) et corps (tâche 1.14).
///
/// Porté de `src/lib/hooks/useChat.tsx` et `src/components/MessageBox.tsx`
/// (web). Côté web, `useChat` referme artificiellement les balises ouvertes
/// (`processedText += '</think> <a> </a>'`), puis `markdown-to-jsx` rend
/// chaque `<think>` en `ThinkBox` et chaque `<tldr>` en carte, à l'endroit
/// même où ils apparaissent. Ici pas de HTML intermédiaire : on produit
/// directement trois textes et une phase typée. La vue les place où elle veut
/// (raisonnement, puis TL;DR, puis corps).
///
/// Les balises sont celles que demande le prompt du mode Approfondi
/// (`PromptTemplates.modeSection`, port de `src/lib/prompts/search/writer.ts`),
/// plus le bloc de réflexion natif de Qwen3, le seul modèle MLX du catalogue.
///
/// LOGIQUE 100 % PURE : aucun état, aucun réseau, aucun accès disque. Le même
/// texte donne toujours le même résultat. Le parsing ne lève JAMAIS : dans le
/// pire des cas, tout le texte finit dans le corps.
///
/// ## Grammaire, par contexte
///
/// **Dans le corps**, les quatre balises sont structurelles :
/// - `<think>` ouvre un bloc de raisonnement ;
/// - `<tldr>` ouvre le TL;DR. Seul le PREMIER compte. Un `<tldr>` suivant est
///   retiré, et son contenu reste dans le corps, à sa place ;
/// - `</tldr>` orphelin est retiré ;
/// - `</think>` orphelin : voir la section dédiée ci-dessous.
///
/// **Dans un bloc de raisonnement**, seul `</think>` est structurel. Tout le
/// reste est recopié tel quel, y compris `<think>` et `<tldr>`. Les modèles à
/// raisonnement récapitulent souvent leurs consignes (« je dois écrire un
/// `<tldr>` ensuite ») : interpréter ces balises casserait le découpage.
///
/// **Dans le TL;DR**, seuls `</tldr>` et un saut de ligne ferment le bloc. Le
/// saut de ligne ne compte qu'une fois du texte écrit.
///
/// ## Écarts assumés vis-à-vis du web
///
/// 1. **Casse et espaces tolérés.** `<THINK>`, `< think >` et `</ tldr>` sont
///    reconnus. Le web ne reconnaît que la forme exacte en minuscules. Un
///    saut de ligne à l'intérieur d'une balise n'est jamais toléré, et le
///    nombre d'espaces est borné (`maxTagPadding`). `<thinking>`, `<think/>`,
///    `List<T>` ou `a<b` restent du texte.
/// 2. **Bloc vide ignoré.** Pour le web, un `</think>` suffit à terminer le
///    raisonnement, même si le bloc est vide. Ici un bloc vide ne compte pas
///    (voir la garantie anti-clignotement sur `ReasoningPhase`).
/// 3. **TL;DR non refermé, fermé au premier saut de ligne.** Le web referme
///    un `<tldr>` orphelin à la toute fin du texte : un petit modèle qui
///    oublie `</tldr>` voit alors TOUTE sa réponse partir dans la carte
///    TL;DR. Le prompt exige UNE phrase ; un saut de ligne après du texte en
///    marque donc la fin de façon fiable. Les balises posées sur leur propre
///    ligne (`<tldr>\nPhrase.\n</tldr>`) restent correctement traitées.
/// 4. **Plusieurs blocs, un seul encadré.** Le web affiche un `ThinkBox` par
///    bloc. Ici les blocs sont concaténés. C'est un cas RÉEL dans Triva :
///    Qwen3 en mode thinking émet son bloc natif, puis écrit le bloc
///    `<think>` de 2 à 4 phrases que lui demande le prompt Approfondi. Une
///    fois le premier bloc terminé, la phase reste `completed` : le second
///    grossit dans l'encadré replié au lieu de le rouvrir. Ce serait
///    exactement le clignotement à éviter.
/// 5. **Balises dans du code : du texte.** Dans le corps, un `<think>` entre
///    backticks (`` `<think>` ``, bloc ```` ``` ````) n'ouvre rien. Une
///    réponse qui EXPLIQUE ces balises (question sur Qwen3, par exemple)
///    verrait sinon sa suite avalée par un faux bloc de raisonnement. La
///    garde s'applique au corps seulement, jamais dans un bloc de
///    raisonnement : un backtick orphelin y ferait ignorer le vrai
///    `</think>`, et la réponse entière disparaîtrait dans l'encadré.
///    L'échec inverse (un backtick orphelin dans le corps avant une vraie
///    balise) affiche la balise brute. C'est visible, jamais caché : le bon
///    sens de l'erreur.
/// 6. **État interrompu.** Voir `ReasoningPhase.interrupted`.
///
/// Même comportement que le web sur un point qui compte : c'est le PREMIER
/// `</think>` qui ferme le bloc, comme la regex non gourmande
/// `/<think>[\s\S]*?<\/think>/` du web (et le découpage des serveurs
/// d'inférence). Compter la profondeur d'imbrication serait plus « juste »
/// sur `<think>A<think>B</think>C</think>`, mais un `<think>` parasite suivi
/// d'un seul `</think>` laisserait alors le bloc ouvert pour toujours, et la
/// réponse entière disparaîtrait dans l'encadré. Laisser déborder un peu de
/// raisonnement dans le corps est un moindre mal.
///
/// ## Le `</think>` orphelin, seule exception au « préfixe stable »
///
/// Un `</think>` rencontré dans le corps AVANT tout élément structurel
/// (aucun `<think>`, aucun `<tldr>`) fait basculer tout le corps accumulé
/// jusque-là dans un bloc de raisonnement terminé. Ce n'est pas un cas
/// d'école. Qwen le documente pour ses modèles « Thinking-2507 » : le gabarit
/// de chat insère lui-même `<think>`, la sortie ne contient donc que
/// `</think>`. DeepSeek-R1 (et ses distillations) se comporte de même depuis
/// que son gabarit force l'ouverture. On reçoit ces sorties telles quelles
/// via un fournisseur BYOK compatible OpenAI (LM Studio, vLLM, serveur
/// Ollama brut).
///
/// Le prix à payer, inévitable sans balise ouvrante : pendant le stream, ce
/// texte s'affiche d'abord comme corps, puis bascule d'un coup dans
/// l'encadré quand `</think>` arrive. La bascule est unique (la phase passe
/// de `absent` à `completed`). Après elle, le préfixe redevient stable.
/// Limite connue et acceptée : une réponse qui cite `</think>` sans
/// backticks, sans aucune balise avant, verrait son début rangé dans
/// l'encadré (replié mais consultable). Entre backticks, la garde n° 5 la
/// protège.
///
/// Un `</think>` orphelin APRÈS un élément structurel est simplement retiré.
///
/// ## Streaming : pourquoi `isStreaming` plutôt qu'un `pendingSuffix`
///
/// Comme `CitationParser`, le segmenteur est sans état et relancé à chaque
/// instantané cumulatif. Il RETIENT une fin de texte qui pourrait encore
/// devenir une balise structurelle (`"<thi"`, `"</"`) plutôt que de l'afficher
/// puis de la voir disparaître. `CitationParser` expose ce fragment dans
/// `pendingSuffix` et laisse la vue le relâcher en fin de flux. Ici, c'est
/// l'appelant qui passe `isStreaming` (le `ChatViewModel.Message` porte déjà
/// ce booléen). Deux raisons :
/// - la fin du flux change la PHASE, pas seulement un suffixe : un bloc
///   encore ouvert passe de `inProgress` à `interrupted` ;
/// - le fragment retenu appartient à un contexte (raisonnement, TL;DR ou
///   corps). La vue ne saurait pas à quelle partie le recoller.
///
/// Avec `isStreaming == false`, tout fragment retenu est rendu comme du texte
/// dans son contexte : une réponse qui se termine vraiment par `<` ne perd
/// rien. La retenue dépend du contexte : dans un bloc de raisonnement, `"<t"`
/// ne peut devenir qu'un `<think>` ou un `<tldr>` recopié tel quel. Il
/// s'affiche donc tout de suite, et seul un début possible de `</think>` est
/// retenu.
///
/// ## Raccords du corps
///
/// Retirer un bloc au milieu du corps laisse deux tronçons à recoller. Les
/// blancs qui entourent le raccord sont normalisés, parce que la bulle rend
/// le texte en préservant les blancs (`MessageBubbleView`,
/// `.inlineOnlyPreservingWhitespace`) :
/// - au moins deux sauts de ligne donnent une seule ligne vide ;
/// - un seul saut de ligne est conservé ;
/// - l'indentation de la ligne suivante est gardée (liste, bloc de code) ;
/// - des espaces seuls donnent une espace ;
/// - des tronçons collés sont séparés par un saut de ligne : un
///   `Intro.<tldr>…</tldr>## Titre` ne doit pas donner `Intro.## Titre`,
///   titre Markdown cassé.
///
/// ## Coût
///
/// Une seule passe linéaire par instantané, sur les octets UTF-8, sans
/// aucune expression régulière. Lire une balise candidate coûte un temps
/// BORNÉ : au plus `maxTagPadding` blancs dans chacun des trois creux, un nom
/// de 5 lettres au plus, soit 17 octets examinés au maximum par `<`. Même un
/// texte fait de milliers de `<` reste donc linéaire (vérifié par les tests
/// de coût). Le total sur un stream reste quadratique en la longueur de la
/// réponse, comme pour `CitationParser` : c'est le prix, assumé, d'un
/// segmenteur sans état qui ne peut pas se désynchroniser du texte affiché.
/// Un pré-filtre sort immédiatement quand le texte ne contient aucun `<`, le
/// cas d'Apple Intelligence et des modes Rapide et Fiable.
///
/// Travailler sur les octets est sûr ici, contrairement au découpage d'une
/// `String`. Les balises sont en ASCII et toutes les coupes tombent sur un
/// octet ASCII, donc sur une frontière de scalaire Unicode. Les tronçons sont
/// recopiés dans des tampons d'octets puis décodés d'un bloc : jamais de
/// `U+FFFD`, jamais d'index de `String` à aligner sur une grappe.
///
/// `nonisolated` : analyse de texte 100 % pure, appelée depuis une vue
/// (`@MainActor`) comme depuis des contextes non isolés, dont les tests. Sous
/// `-default-isolation=MainActor`, elle hériterait sinon de `@MainActor`.
nonisolated struct ReasoningSegmenter: Sendable {

    /// Nombre maximum d'espaces ou de tabulations tolérés dans CHACUN des
    /// trois creux d'une balise (`< / think >`).
    ///
    /// Un modèle en produit au plus un. La borne empêche de retenir
    /// indéfiniment `"texte <        "` en fin de stream. Elle écarte aussi
    /// d'emblée un `<` suivi d'un long blanc. Même rôle que
    /// `CitationParser.maxCitationDigits`.
    static let maxTagPadding = 3

    // MARK: - API publique

    /// Découpe `text` en raisonnement, TL;DR et corps.
    ///
    /// - Parameters:
    ///   - text: l'instantané CUMULATIF de la réponse (tout le texte reçu
    ///     jusqu'ici), pas le dernier morceau.
    ///   - isStreaming: `true` tant que d'autres tokens peuvent arriver.
    ///     Passer `message.isStreaming`. Pour un message terminé, interrompu
    ///     ou relu depuis l'historique, `false` relâche tout fragment retenu
    ///     et fait passer un bloc resté ouvert en `.interrupted`.
    static func segment(_ text: String, isStreaming: Bool) -> ReasoningSegments {
        // Pré-filtre : sans aucun `<`, il ne peut y avoir ni balise ni
        // fragment retenu. C'est la réponse d'Apple Intelligence ou d'un mode
        // sans raisonnement : tout est corps, sans découpage.
        guard text.utf8.contains(ASCII.lessThan) else {
            return ReasoningSegments(
                reasoning: "",
                reasoningPhase: .absent,
                tldr: nil,
                body: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return scan(Array(text.utf8), isStreaming: isStreaming)
    }

    // MARK: - Passe unique

    /// Alterne deux étapes jusqu'à la fin du texte : recopier d'un bloc une
    /// suite d'octets ordinaires, puis traiter l'octet spécial qui l'arrête
    /// (`<`, backtick, saut de ligne selon le contexte). Une balise avortée ne
    /// fait reculer la passe que jusqu'au lendemain de son `<`, et sa lecture
    /// est bornée (voir « Coût ») : chaque octet n'est examiné qu'un nombre
    /// constant de fois, d'où la linéarité.
    private static func scan(_ bytes: [UInt8], isStreaming: Bool) -> ReasoningSegments {
        var state = SegmentationState()
        var cursor = 0

        while cursor < bytes.count {
            let runEnd = state.endOfPlainRun(in: bytes, from: cursor)
            if runEnd > cursor {
                state.appendText(bytes[cursor..<runEnd])
                cursor = runEnd
            } else {
                cursor = state.consumeSpecialByte(in: bytes, at: cursor, isStreaming: isStreaming)
            }
        }

        return state.result(isStreaming: isStreaming)
    }

    // MARK: - Lecture d'une balise

    /// Les quatre balises reconnues.
    private nonisolated enum Tag: CaseIterable {
        case openThink
        case closeThink
        case openTLDR
        case closeTLDR

        init(name: TagName, isClosing: Bool) {
            switch (name, isClosing) {
            case (.think, false): self = .openThink
            case (.think, true): self = .closeThink
            case (.tldr, false): self = .openTLDR
            case (.tldr, true): self = .closeTLDR
            }
        }

        var isClosing: Bool {
            self == .closeThink || self == .closeTLDR
        }
    }

    /// Les deux noms de balise. Aucun n'est préfixe de l'autre, ce qui permet
    /// de les tester l'un après l'autre sans ambiguïté.
    private nonisolated enum TagName: CaseIterable {
        case think
        case tldr

        private static let thinkBytes = Array("think".utf8)
        private static let tldrBytes = Array("tldr".utf8)

        /// Le nom en ASCII minuscule, forme de référence de la comparaison
        /// insensible à la casse.
        var lowercaseBytes: [UInt8] {
            switch self {
            case .think: Self.thinkBytes
            case .tldr: Self.tldrBytes
            }
        }
    }

    /// Issue d'une tentative de lecture de balise commençant à un `<`.
    private nonisolated enum TagScan {
        /// Balise complète. `end` est l'index juste APRÈS le `>`.
        case tag(Tag, end: Int)
        /// Le texte se termine au milieu d'une balise possible. `candidates`
        /// liste ce qu'elle peut encore devenir. C'est ce qui permet une
        /// retenue qui dépend du contexte.
        case truncated(candidates: [Tag])
        /// Pas une balise : le `<` est du texte ordinaire.
        case notATag
    }

    private nonisolated enum NameScan {
        case name(TagName, end: Int)
        case truncated([TagName])
        case notAName
    }

    /// Lit la forme `<` blanc? `/`? blanc? nom blanc? `>`, en ASCII insensible
    /// à la casse. `start` pointe forcément sur un `<`.
    private static func readTag(in bytes: [UInt8], from start: Int) -> TagScan {
        guard var cursor = skipPadding(in: bytes, from: start + 1) else { return .notATag }
        guard cursor < bytes.count else { return .truncated(candidates: Tag.allCases) }

        let isClosing = bytes[cursor] == ASCII.slash
        if isClosing {
            guard let afterSlash = skipPadding(in: bytes, from: cursor + 1) else { return .notATag }
            cursor = afterSlash
            guard cursor < bytes.count else {
                return .truncated(candidates: Tag.allCases.filter(\.isClosing))
            }
        }

        switch readTagName(in: bytes, from: cursor) {
        case .notAName:
            return .notATag
        case .truncated(let names):
            return .truncated(candidates: names.map { Tag(name: $0, isClosing: isClosing) })
        case .name(let name, let end):
            let tag = Tag(name: name, isClosing: isClosing)
            guard let afterName = skipPadding(in: bytes, from: end) else { return .notATag }
            guard afterName < bytes.count else { return .truncated(candidates: [tag]) }
            return bytes[afterName] == ASCII.greaterThan ? .tag(tag, end: afterName + 1) : .notATag
        }
    }

    /// Reconnaît `think` ou `tldr` à partir de `start`. Un nom suivi d'autres
    /// lettres (`thinking`) est bien lu comme `think` ici : c'est l'appelant
    /// qui le rejette, faute de trouver `>` juste après.
    private static func readTagName(in bytes: [UInt8], from start: Int) -> NameScan {
        var truncatedNames: [TagName] = []

        for name in TagName.allCases {
            let expected = name.lowercaseBytes
            var matched = 0
            while matched < expected.count,
                  start + matched < bytes.count,
                  ASCII.lowercased(bytes[start + matched]) == expected[matched] {
                matched += 1
            }
            if matched == expected.count { return .name(name, end: start + matched) }
            if start + matched == bytes.count { truncatedNames.append(name) }
        }

        return truncatedNames.isEmpty ? .notAName : .truncated(truncatedNames)
    }

    /// Saute au plus `maxTagPadding` espaces ou tabulations. Renvoie `nil`
    /// au-delà : ce n'est alors plus une balise plausible.
    private static func skipPadding(in bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count, ASCII.isHorizontalSpace(bytes[cursor]) {
            guard cursor - start < maxTagPadding else { return nil }
            cursor += 1
        }
        return cursor
    }

    // MARK: - Contextes

    /// Là où se trouve la passe. Chaque contexte a ses balises structurelles,
    /// voir « Grammaire, par contexte » sur le type.
    private nonisolated enum Context {
        case body
        case reasoning
        case tldr

        /// Vrai si `tag` a un effet dans ce contexte, faux s'il n'y est que du
        /// texte recopié tel quel.
        func consumes(_ tag: Tag) -> Bool {
            switch self {
            case .body: true
            case .reasoning: tag == .closeThink
            case .tldr: tag == .closeTLDR
            }
        }
    }

    // MARK: - Raccord

    /// Blancs accumulés autour d'un élément retiré du corps, en attendant le
    /// premier caractère visible qui suit (voir « Raccords du corps »).
    ///
    /// On ne décide du séparateur qu'à l'arrivée de ce caractère : jusque-là,
    /// ces blancs seraient de toute façon rognés en fin de corps. La décision
    /// ne revient donc jamais sur un texte déjà affiché.
    private nonisolated struct JunctionWhitespace {
        private var lineBreakCount = 0
        private var hasOtherWhitespace = false
        private var indentation: [UInt8] = []

        mutating func absorb(_ byte: UInt8) {
            if byte == ASCII.lineFeed {
                lineBreakCount += 1
                indentation.removeAll(keepingCapacity: true)
            } else {
                hasOtherWhitespace = true
                if ASCII.isHorizontalSpace(byte) { indentation.append(byte) }
            }
        }

        var separator: [UInt8] {
            switch lineBreakCount {
            case 0: [hasOtherWhitespace ? ASCII.space : ASCII.lineFeed]
            case 1: [ASCII.lineFeed] + indentation
            default: [ASCII.lineFeed, ASCII.lineFeed] + indentation
            }
        }
    }

    // MARK: - État de la passe

    /// État mutable d'UNE passe. Il ne survit jamais à l'appel de `segment` :
    /// le segmenteur reste sans état d'un instantané à l'autre.
    private nonisolated struct SegmentationState {
        private var context: Context = .body
        private var body: [UInt8] = []
        private var junction: JunctionWhitespace?
        /// Longueur de la suite de backticks qui a ouvert le code en cours dans
        /// le corps, `nil` hors code. Un code se referme sur une suite de même
        /// longueur, règle des spans Markdown. Elle couvre aussi les blocs
        /// ```` ``` ````.
        private var codeSpanLength: Int?
        private var closedReasoningBlocks: [[UInt8]] = []
        private var openReasoningBlock: [UInt8] = []
        private var hasSeenReasoningBlock = false
        private var tldr: [UInt8] = []
        private var hasOpenedTLDR = false
        private var tldrHasContent = false

        // MARK: Découpage en suites

        /// Octets qui interrompent une suite de texte ordinaire dans le
        /// contexte courant.
        private func isSpecial(_ byte: UInt8) -> Bool {
            switch context {
            case .body:
                byte == ASCII.backtick || (codeSpanLength == nil && byte == ASCII.lessThan)
            case .reasoning:
                byte == ASCII.lessThan
            case .tldr:
                byte == ASCII.lessThan || byte == ASCII.lineFeed || byte == ASCII.carriageReturn
            }
        }

        func endOfPlainRun(in bytes: [UInt8], from start: Int) -> Int {
            var cursor = start
            while cursor < bytes.count, !isSpecial(bytes[cursor]) { cursor += 1 }
            return cursor
        }

        /// Traite l'octet spécial en `index` et renvoie où reprendre.
        mutating func consumeSpecialByte(in bytes: [UInt8], at index: Int, isStreaming: Bool) -> Int {
            switch bytes[index] {
            case ASCII.backtick:
                return consumeBacktickRun(in: bytes, at: index)
            case ASCII.lessThan:
                return consumeTagCandidate(in: bytes, at: index, isStreaming: isStreaming)
            default:
                // Saut de ligne, spécial dans le seul contexte TL;DR.
                if tldrHasContent { context = .body }
                appendText(bytes[index...index])
                return index + 1
            }
        }

        private mutating func consumeBacktickRun(in bytes: [UInt8], at start: Int) -> Int {
            var end = start
            while end < bytes.count, bytes[end] == ASCII.backtick { end += 1 }

            let runLength = end - start
            if codeSpanLength == nil {
                codeSpanLength = runLength
            } else if codeSpanLength == runLength {
                codeSpanLength = nil
            }

            appendText(bytes[start..<end])
            return end
        }

        private mutating func consumeTagCandidate(in bytes: [UInt8], at start: Int, isStreaming: Bool) -> Int {
            switch ReasoningSegmenter.readTag(in: bytes, from: start) {
            case .tag(let tag, let end):
                if context.consumes(tag) {
                    apply(tag)
                } else {
                    appendText(bytes[start..<end])
                }
                return end

            case .notATag:
                // On n'émet que le `<` et on reprend juste après : la suite
                // est recopiée par la passe normale, sans être réexaminée ici.
                appendText(bytes[start...start])
                return start + 1

            case .truncated(let candidates):
                // Fin de texte au milieu d'une balise possible. On retient
                // seulement si elle peut encore AGIR dans ce contexte ; sinon,
                // ou si le flux est terminé, c'est du texte.
                let mayStillAct = candidates.contains { context.consumes($0) }
                if !(isStreaming && mayStillAct) {
                    appendText(bytes[start...])
                }
                return bytes.count
            }
        }

        // MARK: Balises

        private mutating func apply(_ tag: Tag) {
            switch context {
            case .body:
                applyInBody(tag)
            case .reasoning:
                // Seul `</think>` agit ici, voir `Context.consumes`.
                closedReasoningBlocks.append(openReasoningBlock)
                openReasoningBlock = []
                context = .body
            case .tldr:
                // Seul `</tldr>` agit ici.
                context = .body
            }
        }

        private mutating func applyInBody(_ tag: Tag) {
            // Toute balise du corps en est retirée : les blancs qui
            // l'entourent deviennent un raccord.
            openJunction()

            switch tag {
            case .openThink:
                hasSeenReasoningBlock = true
                openReasoningBlock = []
                context = .reasoning
            case .closeThink:
                // `</think>` orphelin : le gabarit de chat a ouvert le bloc à
                // la place du modèle, tout ce qui précède était du
                // raisonnement. Voir la section dédiée sur le type.
                if !hasSeenReasoningBlock && !hasOpenedTLDR {
                    closedReasoningBlocks.append(body)
                    body = []
                }
                hasSeenReasoningBlock = true
            case .openTLDR:
                guard !hasOpenedTLDR else { return }
                hasOpenedTLDR = true
                context = .tldr
            case .closeTLDR:
                break
            }
        }

        // MARK: Texte

        mutating func appendText(_ chunk: ArraySlice<UInt8>) {
            guard !chunk.isEmpty else { return }

            switch context {
            case .body:
                appendToBody(chunk)
            case .reasoning:
                openReasoningBlock.append(contentsOf: chunk)
            case .tldr:
                tldr.append(contentsOf: chunk)
                if !tldrHasContent {
                    tldrHasContent = chunk.contains { !ASCII.isWhitespace($0) }
                }
            }
        }

        /// Ajoute au corps en résolvant le raccord en attente, s'il y en a un.
        /// Les blancs sont absorbés jusqu'au premier octet visible ; celui-ci
        /// déclenche l'émission du séparateur, sauf si le corps est encore
        /// vide (les blancs de tête seraient rognés de toute façon).
        private mutating func appendToBody(_ chunk: ArraySlice<UInt8>) {
            guard var pending = junction else {
                body.append(contentsOf: chunk)
                return
            }

            var cursor = chunk.startIndex
            while cursor < chunk.endIndex, ASCII.isWhitespace(chunk[cursor]) {
                pending.absorb(chunk[cursor])
                cursor += 1
            }

            guard cursor < chunk.endIndex else {
                junction = pending
                return
            }

            if !body.isEmpty { body.append(contentsOf: pending.separator) }
            junction = nil
            body.append(contentsOf: chunk[cursor...])
        }

        /// Ouvre un raccord, sauf s'il y en a déjà un (éléments retirés à la
        /// suite). Les blancs de fin du corps y migrent pour être normalisés
        /// avec ceux qui suivront. Tant qu'un raccord est ouvert, le corps ne
        /// reçoit aucun blanc : ceux-ci ne sont donc jamais réexaminés.
        private mutating func openJunction() {
            guard junction == nil else { return }

            var pending = JunctionWhitespace()
            var trailingStart = body.endIndex
            while trailingStart > body.startIndex, ASCII.isWhitespace(body[trailingStart - 1]) {
                trailingStart -= 1
            }
            for byte in body[trailingStart...] { pending.absorb(byte) }
            body.removeSubrange(trailingStart...)
            junction = pending
        }

        // MARK: Résultat

        func result(isStreaming: Bool) -> ReasoningSegments {
            let closedTexts = closedReasoningBlocks.map(ASCII.decodeTrimmed).filter { !$0.isEmpty }
            let openText = context == .reasoning ? ASCII.decodeTrimmed(openReasoningBlock) : ""

            let phase: ReasoningPhase = if !closedTexts.isEmpty {
                .completed
            } else if !openText.isEmpty {
                isStreaming ? .inProgress : .interrupted
            } else {
                .absent
            }

            let reasoningParts = openText.isEmpty ? closedTexts : closedTexts + [openText]
            let tldrText = ASCII.decodeTrimmed(tldr)

            return ReasoningSegments(
                reasoning: reasoningParts.joined(separator: "\n\n"),
                reasoningPhase: phase,
                tldr: tldrText.isEmpty ? nil : tldrText,
                body: ASCII.decodeTrimmed(body)
            )
        }
    }

    // MARK: - Octets

    private nonisolated enum ASCII {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let backtick = UInt8(ascii: "`")
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let lineFeed = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")
        private static let verticalTab: UInt8 = 0x0B
        private static let formFeed: UInt8 = 0x0C
        private static let uppercaseLetters = UInt8(ascii: "A")...UInt8(ascii: "Z")

        static func isHorizontalSpace(_ byte: UInt8) -> Bool {
            byte == space || byte == tab
        }

        /// Blanc ASCII. Les blancs Unicode (espace insécable…) comptent comme
        /// du texte visible : ils sont rares dans une sortie de modèle, et le
        /// rognage final les retire de toute façon.
        static func isWhitespace(_ byte: UInt8) -> Bool {
            isHorizontalSpace(byte)
                || byte == lineFeed
                || byte == carriageReturn
                || byte == verticalTab
                || byte == formFeed
        }

        static func lowercased(_ byte: UInt8) -> UInt8 {
            uppercaseLetters.contains(byte) ? byte | 0x20 : byte
        }

        static func decodeTrimmed(_ bytes: [UInt8]) -> String {
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
