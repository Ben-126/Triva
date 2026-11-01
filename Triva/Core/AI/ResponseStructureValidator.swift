//
//  ResponseStructureValidator.swift
//  Triva
//
//  Created by ben podrojsky on 18/09/2026.
//

import Foundation
import NaturalLanguage

/// Une violation de structure repérée dans une réponse générée.
///
/// Type structuré plutôt qu'un `Bool` ou une `[String]` : le plan (1.4)
/// demande explicitement de pouvoir AFFICHER les violations en debug.
/// `kind` permet de filtrer ou compter par catégorie dans un test comme dans
/// un panneau de debug, `detail` explique la règle en français, `excerpt`
/// porte le fragment fautif quand il en existe un (la formulation bannie
/// trouvée, la citation mal formée, la conclusion trop longue…).
nonisolated struct ResponseStructureViolation: Sendable, Equatable {
    /// Catégories volontairement fines : « la réponse est mauvaise » n'aide
    /// personne, « la conclusion fait 4 phrases » se corrige.
    nonisolated enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Réponse vide ou uniquement composée d'espaces. Court-circuite
        /// toutes les autres règles, qui se déclencheraient en cascade.
        case emptyResponse
        /// Aucune citation `[n]` valide alors que le contexte en contenait.
        case missingCitation
        /// Citation présente mais inutilisable : `[0]` (la numérotation
        /// commence à 1), `[1` non refermée, `[1,2]` au lieu de `[1][2]`,
        /// `[abc]`…
        case malformedCitation
        /// Citation `[n]` dont le numéro dépasse le nombre de documents
        /// réellement fournis — donc inventé.
        case citationOutOfRange
        /// Une des formulations bannies par le prompt writer apparaît.
        case bannedPhrase
        /// Plus de 2 phrases après le dernier titre.
        case conclusionTooLong
        /// Mode approfondi, texte long, aucun titre `##`.
        case missingHeadings
        /// Mode approfondi, plusieurs titres contenant « Conclusion ».
        case duplicateConclusionHeading
        /// Mode rapide, plus de 3 phrases.
        case quickModeTooLong
        /// Un bloc de raisonnement ou de TL;DR, tel que `ReasoningSegmenter`
        /// le découpe pour l'affichage, apparaît alors que le prompt
        /// l'interdit pour ce mode (ou cette verbosité).
        case forbiddenReasoningBlock
        /// Mode approfondi détaillé : bloc `<think>` attendu, absent.
        case missingReasoningBlock
        /// Mode approfondi détaillé : bloc `<tldr>` attendu, absent.
        case missingTLDRBlock
        /// Bloc `<think>` ouvert et jamais refermé. C'est LE mode de
        /// défaillance documenté dans `PromptTemplates.modeSection` comme
        /// raison d'être de la variante concise : un petit modèle ouvre
        /// `<think>` et ne le referme pas, et toute la suite de la réponse
        /// part dans l'encadré de raisonnement (`ReasoningPhase.interrupted`).
        /// Un `<tldr>` sans `</tldr>` n'en est pas un : le segmenteur le
        /// ferme au premier saut de ligne, la carte s'affiche correctement.
        case unclosedReasoningBlock
    }

    let kind: Kind
    let detail: String
    let excerpt: String?

    nonisolated init(kind: Kind, detail: String, excerpt: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.excerpt = excerpt
    }
}

/// Rapport complet d'une validation. Porte le mode ET la verbosité analysés
/// en plus des violations : une violation n'a de sens qu'en regard des
/// consignes réellement envoyées au modèle (voir
/// `PromptTemplates.modeSection(for:complexity:)`), et un rapport détaché de
/// ce contexte est ininterprétable trois jours plus tard.
nonisolated struct ResponseStructureReport: Sendable, Equatable {
    let mode: ResponseMode
    let complexity: WriterPromptComplexity
    let violations: [ResponseStructureViolation]

    nonisolated init(mode: ResponseMode, complexity: WriterPromptComplexity, violations: [ResponseStructureViolation]) {
        self.mode = mode
        self.complexity = complexity
        self.violations = violations
    }

    nonisolated var isClean: Bool { violations.isEmpty }

    nonisolated func contains(_ kind: ResponseStructureViolation.Kind) -> Bool {
        violations.contains { $0.kind == kind }
    }

    nonisolated func count(of kind: ResponseStructureViolation.Kind) -> Int {
        violations.filter { $0.kind == kind }.count
    }

    /// Rendu texte destiné au débogage pendant le développement (console ou
    /// panneau de debug), jamais à l'utilisateur final : ce validateur est un
    /// garde-fou d'observation, pas un message d'erreur produit.
    nonisolated var debugSummary: String {
        guard !isClean else {
            return "Structure conforme (mode \(mode.rawValue), consignes \(complexity))."
        }
        let lines = violations.map { violation -> String in
            if let excerpt = violation.excerpt {
                return "- \(violation.kind.rawValue) : \(violation.detail) — « \(excerpt) »"
            }
            return "- \(violation.kind.rawValue) : \(violation.detail)"
        }
        return (["\(violations.count) violation(s) (mode \(mode.rawValue)) :"] + lines).joined(separator: "\n")
    }
}

/// Vérifie qu'un texte de réponse respecte les règles de structure imposées
/// par `PromptTemplates`.
///
/// Ce que ce type N'EST PAS, et c'est le point important : ni un correcteur,
/// ni un bloqueur. Il ne réécrit rien, ne `throw` jamais, et son rapport
/// n'empêche aucune réponse de s'afficher. La génération d'un LLM n'est pas
/// déterministe : un test unitaire sur « la qualité » du texte serait une
/// illusion. Ce validateur teste donc ses PROPRES règles sur des textes fixes
/// (déterministe), et peut ensuite être branché sur de vraies réponses
/// pendant le développement pour repérer les dérives — typiquement quand on
/// compare les 3 moteurs IA sur un même prompt, ou qu'on vérifie qu'un MLX
/// 0.6B n'effondre pas la structure (checklist 1.4).
///
/// Principe directeur en cas de doute : **ne jamais crier au loup**. Un
/// validateur qui signale une violation là où le prompt n'en imposait aucune
/// est pire qu'un validateur absent — on cesse de le lire. C'est ce qui
/// justifie les exemptions de `citationViolations` et le sous-comptage assumé
/// de `sentences(in:)`.
///
/// Toutes les comparaisons de texte replient la casse ET les diacritiques :
/// un modèle qui écrit « en resume » sans accent, ou « En Résumé » en tête de
/// phrase, est attrapé comme les autres.
///
/// ## Blocs `<think>` / `<tldr>` : la grammaire de `ReasoningSegmenter` (I1b)
/// Le validateur ne cherche plus les balises exactes `"<think>"` et
/// `"</think>"` dans le texte : il juge le découpage que
/// `ReasoningSegmenter.segment(_:isStreaming: false)` produit pour
/// l'affichage, donc ce que l'utilisateur VOIT. Avant, les deux divergeaient
/// (divergence relevée à l'étape A) :
/// - `<THINK>` ou `< think >` : affichés comme un encadré de raisonnement,
///   mais ignorés ici (bloc interdit non signalé, bloc exigé « absent ») ;
/// - `` `<think>` `` entre backticks, dans une réponse qui EXPLIQUE la
///   balise : du simple texte pour l'affichage, mais un « bloc interdit »
///   ici — un faux positif, le pire défaut de cet outil.
/// Conséquences assumées de l'alignement :
/// - un bloc VIDE (le `<think>\n\n</think>` de Qwen3 en mode non-thinking)
///   n'est plus signalé : l'encadré ne s'affiche pas ;
/// - un `</think>` orphelin en tête (gabarits Qwen « Thinking-2507 »,
///   DeepSeek-R1) compte comme un raisonnement, comme à l'affichage ;
/// - un `<tldr>` refermé par un saut de ligne plutôt que `</tldr>` n'est pas
///   « non refermé » : la carte TL;DR s'affiche correctement.
/// Les autres règles (citations, formulations, longueurs, titres) lisent
/// toujours le texte complet, comme avant.
nonisolated struct ResponseStructureValidator: Sendable {
    private let bannedPhrases: [String]
    private let maxConclusionSentences: Int
    private let maxQuickModeSentences: Int
    private let deepModeHeadingWordThreshold: Int

    /// Les valeurs par défaut viennent toutes de `PromptTemplates` : c'est le
    /// prompt qui fixe la règle, le validateur ne fait que constater. Les
    /// redéclarer ici avec leurs propres constantes garantirait une dérive au
    /// premier ajustement du prompt.
    ///
    /// - `maxConclusionSentences: 2` — « Conclusion : 2 phrases MAXIMUM » du
    ///   mode approfondi, repris du web (`2 sentences MAXIMUM — 3 or more is
    ///   a hard violation`).
    /// - `maxQuickModeSentences: 3` — « EXACTEMENT 2 à 3 phrases » du mode
    ///   rapide.
    ///
    /// `nonisolated` explicite : sous `-default-isolation=MainActor`, un
    /// `init` non annoté est isolé au main actor même dans un type `Sendable`
    /// (vérifié au typecheck), ce qui interdirait de construire le validateur
    /// depuis un contexte nonisolated.
    nonisolated init(
        bannedPhrases: [String] = PromptTemplates.allBannedPhrases,
        maxConclusionSentences: Int = 2,
        maxQuickModeSentences: Int = 3,
        deepModeHeadingWordThreshold: Int = PromptTemplates.deepModeHeadingWordThreshold
    ) {
        self.bannedPhrases = bannedPhrases
        self.maxConclusionSentences = maxConclusionSentences
        self.maxQuickModeSentences = maxQuickModeSentences
        self.deepModeHeadingWordThreshold = deepModeHeadingWordThreshold
    }

    /// - Parameters:
    ///   - text: la réponse générée, telle qu'affichée.
    ///   - mode: le mode de réponse demandé — les règles de forme en
    ///     dépendent entièrement.
    ///   - complexity: la verbosité des consignes réellement envoyées. En
    ///     `deep` + `.concise`, le prompt INTERDIT `<think>`/`<tldr>` au lieu
    ///     de les exiger (voir `PromptTemplates.modeSection`) : sans ce
    ///     paramètre, le validateur signalerait des violations que le prompt
    ///     n'a jamais demandées.
    ///   - citableSourceCount: nombre de documents du contexte, si connu —
    ///     à obtenir de `PromptTemplates.citableDocumentCount(sources:scrapedPages:)`,
    ///     jamais de `sources.count` (la fusion par URL peut faire diverger
    ///     les deux). `0` signifie « contexte vide » et lève l'exigence de
    ///     citation ; `nil` signifie « inconnu » et garde toutes les règles
    ///     sauf la détection des numéros inventés.
    nonisolated func validate(
        _ text: String,
        mode: ResponseMode,
        complexity: WriterPromptComplexity = .full,
        citableSourceCount: Int? = nil
    ) -> ResponseStructureReport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ResponseStructureReport(
                mode: mode,
                complexity: complexity,
                violations: [
                    ResponseStructureViolation(
                        kind: .emptyResponse,
                        detail: "La réponse est vide : aucune autre règle n'est vérifiable."
                    )
                ]
            )
        }

        let segments = ReasoningSegmenter.segment(trimmed, isStreaming: false)
        var violations: [ResponseStructureViolation] = []
        violations.append(contentsOf: citationViolations(in: trimmed, citableSourceCount: citableSourceCount))
        violations.append(contentsOf: bannedPhraseViolations(in: trimmed))
        violations.append(contentsOf: conclusionViolations(in: trimmed))
        violations.append(contentsOf: modeViolations(in: trimmed, segments: segments, mode: mode, complexity: complexity))

        return ResponseStructureReport(mode: mode, complexity: complexity, violations: violations)
    }

    // MARK: - Règles communes à tous les modes

    /// Deux exemptions, sans lesquelles le validateur signalerait des
    /// réponses PARFAITEMENT conformes au prompt — le pire défaut possible
    /// pour un outil d'observation :
    ///
    /// 1. `PromptTemplates.noRelevantInformationAnswer` est la phrase que le
    ///    prompt impose mot pour mot quand le contexte ne contient rien
    ///    d'utile. Elle ne cite rien, par construction.
    /// 2. `citableSourceCount == 0` : il n'y a aucun document à citer. Ce cas
    ///    couvre la requête conversationnelle (« réponds naturellement, sans
    ///    citation ») et le mode Fiable sans source, où le prompt impose
    ///    d'ouvrir par `unverifiedSourcesWarning` et de marquer chaque phrase
    ///    par `unsupportedClaimMarker` — toujours sans aucune citation.
    ///
    /// Les citations mal formées et hors plage restent vérifiées dans le cas
    /// 2 : un modèle qui invente `[3]` alors que le contexte est vide est une
    /// vraie information, pas un faux positif.
    private nonisolated func citationViolations(in text: String, citableSourceCount: Int?) -> [ResponseStructureViolation] {
        guard !Self.isNoRelevantInformationAnswer(text) else { return [] }

        var violations: [ResponseStructureViolation] = []
        let scan = Self.scanCitations(in: text)

        if scan.validNumbers.isEmpty, citableSourceCount != 0 {
            violations.append(
                ResponseStructureViolation(
                    kind: .missingCitation,
                    detail: "Aucune citation [n] valide : le prompt exige une citation par affirmation factuelle."
                )
            )
        }

        for token in scan.malformedTokens {
            violations.append(
                ResponseStructureViolation(
                    kind: .malformedCitation,
                    detail: "Citation inutilisable : la forme attendue est [1], et [1][2] pour plusieurs sources.",
                    excerpt: token
                )
            )
        }

        if let citableSourceCount {
            for number in scan.validNumbers where number > citableSourceCount {
                violations.append(
                    ResponseStructureViolation(
                        kind: .citationOutOfRange,
                        detail: "Le contexte ne contient que \(citableSourceCount) document(s) : ce numéro est inventé.",
                        excerpt: "[\(number)]"
                    )
                )
            }
        }

        return violations
    }

    private nonisolated func bannedPhraseViolations(in text: String) -> [ResponseStructureViolation] {
        bannedPhrases.compactMap { phrase -> ResponseStructureViolation? in
            guard Self.contains(phrase, in: text) else { return nil }
            return ResponseStructureViolation(
                kind: .bannedPhrase,
                detail: "Formulation interdite par le prompt writer (spéculation ou remplissage).",
                excerpt: phrase
            )
        }
    }

    /// « Conclusion » est définie comme le texte qui suit le DERNIER titre,
    /// quel que soit son libellé — c'est la définition littérale du plan
    /// (« ≤ 2 phrases détectées après le dernier titre »), et la seule qui
    /// tienne quand le modèle intitule sa dernière section « Ce qu'il faut
    /// retenir » plutôt que « Conclusion ».
    ///
    /// Un texte sans aucun titre n'a donc pas de conclusion analysable et
    /// n'est pas contrôlé ici : c'est volontaire, et couvert ailleurs
    /// (`missingHeadings` en mode approfondi, `quickModeTooLong` en mode
    /// rapide).
    private nonisolated func conclusionViolations(in text: String) -> [ResponseStructureViolation] {
        guard let conclusion = Self.textAfterLastHeading(in: text), !conclusion.isEmpty else {
            return []
        }
        let sentences = Self.sentences(in: conclusion)
        guard sentences.count > maxConclusionSentences else { return [] }

        return [
            ResponseStructureViolation(
                kind: .conclusionTooLong,
                detail: "\(sentences.count) phrases après le dernier titre, maximum autorisé : \(maxConclusionSentences).",
                excerpt: conclusion
            )
        ]
    }

    // MARK: - Règles propres au mode

    private nonisolated func modeViolations(
        in text: String,
        segments: ReasoningSegments,
        mode: ResponseMode,
        complexity: WriterPromptComplexity
    ) -> [ResponseStructureViolation] {
        switch mode {
        case .quick:
            return quickModeViolations(in: text, segments: segments)
        case .deep:
            return deepModeViolations(in: text, segments: segments, complexity: complexity)
        case .reliable:
            return forbiddenBlockViolations(in: segments, reason: "le mode Fiable exige une réponse directe")
        }
    }

    private nonisolated func quickModeViolations(in text: String, segments: ReasoningSegments) -> [ResponseStructureViolation] {
        var violations = forbiddenBlockViolations(in: segments, reason: "le mode Rapide exige une réponse directe")

        let sentences = Self.sentences(in: text)
        if sentences.count > maxQuickModeSentences {
            violations.append(
                ResponseStructureViolation(
                    kind: .quickModeTooLong,
                    detail: "\(sentences.count) phrases, maximum autorisé en mode Rapide : \(maxQuickModeSentences).",
                    excerpt: sentences.dropFirst(maxQuickModeSentences).first
                )
            )
        }

        return violations
    }

    private nonisolated func deepModeViolations(
        in text: String,
        segments: ReasoningSegments,
        complexity: WriterPromptComplexity
    ) -> [ResponseStructureViolation] {
        var violations: [ResponseStructureViolation] = []
        let headings = Self.headings(in: text)
        let wordCount = Self.wordCount(of: text)

        if headings.isEmpty, wordCount >= deepModeHeadingWordThreshold {
            violations.append(
                ResponseStructureViolation(
                    kind: .missingHeadings,
                    detail: "Réponse longue (\(wordCount) mots) sans aucun titre ## : le mode Approfondi les impose."
                )
            )
        }

        let conclusionHeadings = headings.filter { Self.contains("conclusion", in: $0) }
        if conclusionHeadings.count > 1 {
            violations.append(
                ResponseStructureViolation(
                    kind: .duplicateConclusionHeading,
                    detail: "\(conclusionHeadings.count) titres de conclusion : le prompt en impose exactement un.",
                    excerpt: conclusionHeadings.joined(separator: " / ")
                )
            )
        }

        switch complexity {
        case .full:
            violations.append(contentsOf: requiredBlockViolations(in: segments))
        case .concise:
            // Les consignes concises INTERDISENT ces blocs à un petit modèle
            // (voir `PromptTemplates.modeSection`) : les exiger ici
            // reprocherait au modèle une consigne qu'on ne lui a pas donnée.
            violations.append(
                contentsOf: forbiddenBlockViolations(in: segments, reason: "les consignes concises interdisent ces blocs")
            )
        }

        return violations
    }

    /// Blocs attendus en mode approfondi détaillé, jugés sur le découpage
    /// d'affichage (voir « Blocs » sur le type). La vérification de fermeture
    /// n'est faite QUE là où le bloc est autorisé : ailleurs, le bloc déclenche
    /// déjà `forbiddenReasoningBlock`, et empiler deux violations pour le même
    /// symptôme rendrait le rapport illisible. Pour la même raison, un
    /// `<think>` resté ouvert ne signale pas EN PLUS l'absence de TL;DR : le
    /// TL;DR est alors, le plus souvent, avalé par le bloc ouvert.
    private nonisolated func requiredBlockViolations(in segments: ReasoningSegments) -> [ResponseStructureViolation] {
        let missingTLDR = segments.tldr == nil
            ? [
                ResponseStructureViolation(
                    kind: .missingTLDRBlock,
                    detail: "Bloc <tldr>...</tldr> d'une phrase attendu après </think> et avant le premier titre."
                ),
            ]
            : []

        switch segments.reasoningPhase {
        case .interrupted:
            return [
                ResponseStructureViolation(
                    kind: .unclosedReasoningBlock,
                    detail: "Balise <think> jamais refermée : toute la suite de la réponse part dans l'encadré de raisonnement.",
                    excerpt: "<think>"
                ),
            ]
        case .absent:
            let missingReasoning = ResponseStructureViolation(
                kind: .missingReasoningBlock,
                detail: "Bloc <think>...</think> attendu en tête de réponse (consignes détaillées, mode Approfondi)."
            )
            return [missingReasoning] + missingTLDR
        case .completed, .inProgress:
            // `.inProgress` n'apparaît que pendant un stream (`isStreaming`
            // vaut `false` ici) : traité comme un bloc présent.
            return missingTLDR
        }
    }

    /// Un bloc de raisonnement affiché (non vide, refermé ou non) et un TL;DR
    /// affiché comptent chacun pour une violation.
    private nonisolated func forbiddenBlockViolations(in segments: ReasoningSegments, reason: String) -> [ResponseStructureViolation] {
        let reasoning = segments.hasReasoning ? ["<think>"] : []
        let tldr = segments.tldr != nil ? ["<tldr>"] : []
        return (reasoning + tldr).map { marker in
            ResponseStructureViolation(
                kind: .forbiddenReasoningBlock,
                detail: "Bloc \(marker) présent alors que \(reason).",
                excerpt: marker
            )
        }
    }

    // MARK: - Analyse de texte (fonctions pures, testables directement)

    /// Résultat du balayage des citations : les numéros valides trouvés (dans
    /// l'ordre d'apparition, doublons conservés) et les jetons visiblement
    /// fautifs.
    nonisolated struct CitationScan: Sendable, Equatable {
        let validNumbers: [Int]
        let malformedTokens: [String]
    }

    /// Longueur maximale du contenu entre crochets encore considéré comme une
    /// tentative de citation. 16 caractères : une citation légitime en fait
    /// au plus 2 ou 3 (`[12]`), une faute plausible du modèle guère plus
    /// (`[1,2,3]`, `[source 1]`), tandis qu'une parenthèse de prose entre
    /// crochets (« [voir la note en bas de page] ») dépasse largement ce
    /// seuil et doit être ignorée plutôt que signalée.
    nonisolated static let maxCitationContentLength = 16

    /// Balayage manuel plutôt qu'une expression régulière : la règle de
    /// décision tient en quelques cas qui doivent rester explicables, ce
    /// qu'une regex à lookahead ne serait plus.
    ///
    /// Pour chaque `[` rencontré, on lit le contenu jusqu'au `]` (en
    /// s'arrêtant à un retour à la ligne, à un `[` imbriqué, ou au-delà de
    /// `maxCitationContentLength`), puis :
    ///
    /// - pas de `]` exploitable : `malformed` seulement si le contenu lu
    ///   était numérique (`[1` non refermée). Sinon c'est un crochet de
    ///   prose, ignoré.
    /// - `]` immédiatement suivi de `(` : lien markdown `[texte](url)`,
    ///   ignoré — c'est la seule construction courante qui produirait un faux
    ///   positif massif.
    /// - contenu uniquement fait de points ou de points de suspension
    ///   (`[...]`, `[…]`) : insertion éditoriale, ignorée.
    /// - contenu entièrement numérique : citation valide si ≥ 1, `malformed`
    ///   si `[0]` (la numérotation du contexte commence à 1) ou si le nombre
    ///   déborde d'un `Int`.
    /// - tout le reste (`[abc]`, `[1,2]`, `[1-2]`, `[ 1 ]`) : `malformed`.
    ///   Le prompt impose `[1][2]` ; une virgule ou du texte entre crochets
    ///   est une citation que l'app ne saura pas relier à sa source, donc un
    ///   vrai défaut à signaler.
    nonisolated static func scanCitations(in text: String) -> CitationScan {
        var validNumbers: [Int] = []
        var malformedTokens: [String] = []

        var index = text.startIndex
        while let openIndex = text[index...].firstIndex(of: "[") {
            let afterOpen = text.index(after: openIndex)
            var cursor = afterOpen
            var content = ""
            var closeIndex: String.Index?

            while cursor < text.endIndex, content.count < maxCitationContentLength {
                let character = text[cursor]
                if character == "]" {
                    closeIndex = cursor
                    break
                }
                if character == "[" || character.isNewline {
                    break
                }
                content.append(character)
                cursor = text.index(after: cursor)
            }

            guard let closeIndex else {
                if !content.isEmpty, content.allSatisfy({ $0.isNumber }) {
                    malformedTokens.append("[" + content)
                }
                // Toujours au moins un caractère de progression : `cursor`
                // vaut `afterOpen` quand la boucle s'est arrêtée tout de
                // suite, donc jamais `openIndex` — aucune boucle infinie.
                index = cursor > afterOpen ? cursor : afterOpen
                continue
            }

            index = text.index(after: closeIndex)

            if index < text.endIndex, text[index] == "(" {
                continue
            }
            if content.isEmpty {
                continue
            }
            if content.allSatisfy({ $0 == "." || $0 == "…" }) {
                continue
            }
            if content.allSatisfy({ $0.isNumber }) {
                if let number = Int(content), number >= 1 {
                    validNumbers.append(number)
                } else {
                    malformedTokens.append("[\(content)]")
                }
                continue
            }
            malformedTokens.append("[\(content)]")
        }

        return CitationScan(validNumbers: validNumbers, malformedTokens: malformedTokens)
    }

    /// Reconnaît la réponse « aucune information fiable » imposée mot pour
    /// mot par `PromptTemplates`. Les guillemets éventuellement ajoutés
    /// autour par le modèle sont retirés avant comparaison : un modèle qui
    /// recopie une phrase citée entre guillemets dans le prompt la rend
    /// souvent avec ses guillemets.
    nonisolated static func isNoRelevantInformationAnswer(_ text: String) -> Bool {
        let stripped = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'“” "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = PromptTemplates.noRelevantInformationAnswer
        return stripped.compare(
            expected,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: nil
        ) == .orderedSame
    }

    /// Comparaison insensible à la casse ET aux diacritiques, locale
    /// explicitement ignorée (`locale: nil`) pour rester déterministe quel
    /// que soit l'appareil.
    nonisolated static func contains(_ needle: String, in haystack: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], locale: nil) != nil
    }

    /// Titres markdown de niveau 2 ou plus (`##`, `###`…), débarrassés de
    /// leurs dièses. Le niveau 1 (`#`) est volontairement ignoré : le prompt
    /// interdit tout titre principal, et un `#` isolé relève d'un autre
    /// problème que la structure des sections.
    nonisolated static func headings(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("##") }
            .map { line in line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
    }

    /// Texte situé après la dernière ligne de titre. `nil` si le texte ne
    /// contient aucun titre.
    nonisolated static func textAfterLastHeading(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let lastHeadingIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("##") }) else {
            return nil
        }
        return lines[(lastHeadingIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Découpage en phrases via `NLTokenizer` (natif, zéro dépendance),
    /// suivi d'une passe de RECOLLAGE maison.
    ///
    /// Pourquoi le recollage : `NLTokenizer` coupe parfois sur un point qui
    /// ne termine pas une phrase — après une abréviation (« M. »), une
    /// initiale (« J. »), un nombre, ou des points de suspension. Sans
    /// correction, « M. Dupont a dit... 3.5 % environ. » compterait 3 phrases
    /// et déclencherait une violation de longueur imaginaire. Le recollage
    /// rend aussi le résultat STABLE : que le tokenizer ait coupé ou non, le
    /// compte final est le même — c'est ce qui permet d'écrire des tests qui
    /// ne dépendent pas des détails d'implémentation d'Apple.
    ///
    /// Arbitrage assumé : en cas de doute on RECOLLE (on sous-compte) plutôt
    /// que de couper. Une violation inventée (« ta conclusion fait 3
    /// phrases » alors qu'elle en fait 2) détruit la confiance dans l'outil,
    /// alors qu'une violation manquée coûte seulement une occasion de la
    /// voir.
    nonisolated static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed

        // `tokens(for:)` plutôt que `enumerateTokens(in:using:)` : renvoie
        // directement le tableau des plages, donc aucune closure à capturer —
        // une closure imposerait de muter un tableau capturé, ce que la
        // vérification de concurrence stricte peut refuser selon l'annotation
        // exacte de l'API système.
        let fragments = tokenizer.tokens(for: trimmed.startIndex..<trimmed.endIndex)
            .map { String(trimmed[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Repli documenté : si le tokenizer ne renvoie rien d'exploitable
        // (langue non reconnue, texte exotique), on considère le texte comme
        // UNE phrase plutôt que zéro — zéro ferait passer silencieusement
        // toutes les règles de longueur.
        guard !fragments.isEmpty else { return [trimmed] }

        return mergeFalseSentenceBreaks(fragments)
    }

    /// Recolle un fragment au suivant quand il se termine par un point qui ne
    /// termine visiblement pas une phrase. Exposé (non `private`) pour être
    /// testable avec des fragments synthétiques : c'est la seule façon de
    /// vérifier le recollage sans dépendre du découpage réel de
    /// `NLTokenizer`, qui peut changer d'une version d'OS à l'autre.
    nonisolated static func mergeFalseSentenceBreaks(_ fragments: [String]) -> [String] {
        var merged: [String] = []
        for fragment in fragments {
            if let previous = merged.last, continuesOnNextFragment(previous) {
                merged[merged.count - 1] = previous + " " + fragment
            } else {
                merged.append(fragment)
            }
        }
        return merged
    }

    /// Abréviations qui ne terminent jamais une phrase en français courant.
    /// « etc. » en est volontairement absent : il termine très souvent une
    /// phrase, l'ajouter produirait un sous-comptage systématique. Écrites
    /// sans accent et en minuscules, la comparaison repliant casse et
    /// diacritiques.
    private nonisolated static let nonTerminalAbbreviations: Set<String> = [
        "m.", "mm.", "mme.", "mmes.", "mlle.", "dr.", "pr.", "me.",
        "st.", "ste.", "cf.", "ex.", "env.", "vs.", "fig.", "art.", "ref.", "no.", "p.",
    ]

    nonisolated static func continuesOnNextFragment(_ fragment: String) -> Bool {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Points de suspension : jamais une fin de phrase sûre.
        if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") {
            return true
        }

        guard let lastToken = trimmed.split(whereSeparator: { $0.isWhitespace }).last else { return false }
        let token = String(lastToken)

        let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if nonTerminalAbbreviations.contains(folded) {
            return true
        }

        guard token.hasSuffix(".") else { return false }
        let stem = String(token.dropLast())
        guard !stem.isEmpty else { return false }

        // Initiale isolée : le « J. » de « J. Dupont ».
        if stem.count == 1, let character = stem.first, character.isUppercase {
            return true
        }
        // Nombre suivi d'un point : le « 3. » de « 3.5 » découpé par erreur.
        if stem.allSatisfy({ $0.isNumber }) {
            return true
        }

        return false
    }
}
