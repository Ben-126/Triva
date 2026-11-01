//
//  ReasoningSegmenterTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

// Aucune suite de ce fichier n'est `@MainActor`, et c'est voulu.
// `ReasoningSegmenter` et ses types de résultat sont `nonisolated` : les
// appeler et les comparer depuis des fonctions de test NON isolées prouve ce
// contrat à la compilation. Expérience faite : si `ReasoningSegmenter.swift`
// perd ses annotations `nonisolated`, la cible Triva compile toujours (tout
// hérite alors de `@MainActor`, isolation par défaut de la cible). C'est ce
// fichier-ci qui cesse de compiler en mode Swift 6 : appel isolé depuis un
// contexte non isolé, conformance `Equatable` isolée. L'erreur tombe bien
// avant qu'un appel hors du thread principal ne pose problème à l'exécution.
// Le test de coût en profite aussi : une suite non isolée ne partage pas un
// exécuteur sérialisé avec les autres, donc sa mesure reste juste (même
// exception que dans `WidgetExecutorTests.swift`).

// MARK: - Outils

/// Segmente un texte COMPLET : message terminé, interrompu, ou relu depuis
/// l'historique.
private func segmentFinal(_ text: String) -> ReasoningSegments {
    ReasoningSegmenter.segment(text, isStreaming: false)
}

/// Segmente un instantané cumulatif en cours de stream.
private func segmentStreaming(_ text: String) -> ReasoningSegments {
    ReasoningSegmenter.segment(text, isStreaming: true)
}

/// Fabrique un résultat attendu. Les valeurs par défaut décrivent une réponse
/// vide, sans raisonnement ni TL;DR, ce qui garde chaque test lisible.
private func segments(
    reasoning: String = "",
    phase: ReasoningPhase = .absent,
    tldr: String? = nil,
    body: String = ""
) -> ReasoningSegments {
    ReasoningSegments(reasoning: reasoning, reasoningPhase: phase, tldr: tldr, body: body)
}

/// Rang de la phase dans l'ordre où elle doit progresser pendant un stream.
/// `interrupted` n'a pas de rang : il ne doit JAMAIS apparaître tant que
/// `isStreaming` est vrai.
private func progressionRank(of phase: ReasoningPhase) -> Int? {
    switch phase {
    case .absent: 0
    case .inProgress: 1
    case .completed: 2
    case .interrupted: nil
    }
}

/// Rejoue `answer` caractère par caractère, comme un vrai stream qui livre des
/// instantanés cumulatifs. Vérifie à CHAQUE instantané les garanties
/// anti-clignotement :
/// 1. la phase ne régresse jamais, et n'est jamais `interrupted` en plein stream ;
/// 2. chaque partie ne fait que grandir par la fin, sans jamais être réécrite ;
/// 3. `absent` ⟺ raisonnement vide ;
/// 4. aucun fragment de balise n'est jamais affiché. Les réponses rejouées ne
///    contiennent donc aucun `<` en dehors de leurs balises.
///
/// `startLength` permet de ne commencer les vérifications qu'après une bascule
/// documentée (le `</think>` orphelin). Renvoie le résultat de chaque
/// instantané vérifié, dans l'ordre.
@discardableResult
private func replayStreaming(_ answer: String, from startLength: Int = 0) -> [ReasoningSegments] {
    var previous = segmentStreaming(String(answer.prefix(startLength)))
    var history: [ReasoningSegments] = []

    for length in (startLength + 1)...answer.count {
        let current = segmentStreaming(String(answer.prefix(length)))
        let previousRank = progressionRank(of: previous.reasoningPhase) ?? Int.max
        let currentRank = progressionRank(of: current.reasoningPhase)

        #expect(currentRank != nil, "Phase interrompue en plein stream au préfixe \(length)")
        #expect((currentRank ?? -1) >= previousRank, "La phase a régressé au préfixe \(length)")
        #expect(current.reasoning.hasPrefix(previous.reasoning), "Raisonnement réécrit au préfixe \(length)")
        #expect((current.tldr ?? "").hasPrefix(previous.tldr ?? ""), "TL;DR réécrit au préfixe \(length)")
        #expect(current.body.hasPrefix(previous.body), "Corps réécrit au préfixe \(length)")
        #expect((current.reasoningPhase == .absent) == current.reasoning.isEmpty, "Invariant absent/vide rompu au préfixe \(length)")

        let displayed = current.reasoning + (current.tldr ?? "") + current.body
        #expect(!displayed.contains("<"), "Fragment de balise affiché au préfixe \(length)")

        history.append(current)
        previous = current
    }

    return history
}

// MARK: - Réponses réalistes

private enum Answers {

    /// Mode Approfondi bien formé : bloc <think>, TL;DR, sections.
    static let deepMode = """
    <think>
    La question porte sur la hauteur de la tour Eiffel. La source [1] donne 330 mètres, la source [2] l'ancienne valeur de 324 mètres : l'antenne ajoutée en 2022 explique l'écart.
    </think>
    <tldr>La tour Eiffel mesure 330 mètres depuis l'ajout d'une antenne en 2022.</tldr>
    ## Hauteur actuelle
    La tour culmine à 330 mètres[1].

    ## Évolution
    Elle mesurait 324 mètres avant 2022[2].
    """

    static let deepModeExpected = segments(
        reasoning: "La question porte sur la hauteur de la tour Eiffel. La source [1] donne 330 mètres, "
            + "la source [2] l'ancienne valeur de 324 mètres : l'antenne ajoutée en 2022 explique l'écart.",
        phase: .completed,
        tldr: "La tour Eiffel mesure 330 mètres depuis l'ajout d'une antenne en 2022.",
        body: "## Hauteur actuelle\nLa tour culmine à 330 mètres[1].\n\n## Évolution\nElle mesurait 324 mètres avant 2022[2]."
    )

    /// Qwen3 en mode thinking avec le prompt Approfondi : son bloc natif, PUIS
    /// le bloc court demandé par le prompt. Deux blocs, un seul encadré.
    static let qwenDoubleBlock = """
    <think>
    Okay, l'utilisateur demande la capitale de l'Australie. Les sources [1] et [2] disent Canberra.
    </think>

    <think>Question : capitale de l'Australie. Sources [1][2] concordantes.</think>
    <tldr>La capitale de l'Australie est Canberra.</tldr>
    ## Réponse
    Canberra est la capitale fédérale depuis 1913[1].
    """

    static let qwenDoubleBlockExpected = segments(
        reasoning: "Okay, l'utilisateur demande la capitale de l'Australie. Les sources [1] et [2] disent Canberra."
            + "\n\nQuestion : capitale de l'Australie. Sources [1][2] concordantes.",
        phase: .completed,
        tldr: "La capitale de l'Australie est Canberra.",
        body: "## Réponse\nCanberra est la capitale fédérale depuis 1913[1]."
    )

    /// Qwen3 en mode non-thinking (`/no_think`) : bloc VIDE, puis la réponse.
    static let qwenEmptyBlock = "<think>\n\n</think>\n\nCanberra est la capitale de l'Australie[1]."

    /// Petit modèle qui oublie `</tldr>` : la phrase se termine par un saut de ligne.
    static let unclosedTLDR = "<tldr>Le Mont-Blanc culmine à 4 805 mètres.\n\n## Altitude\nLa mesure date de 2023[1]."

    /// Bloc de raisonnement au milieu du texte, entre deux paragraphes.
    static let midTextBlock = "Paris est la capitale.\n\n<think>Vérifier la population dans [1].</think>\n\n"
        + "Elle compte 2,1 millions d'habitants[1]."

    /// Sortie d'un modèle dont le gabarit pré-remplit `<think>` : seule la
    /// balise fermante apparaît.
    static let prefilledReasoning = "Je compare les sources [1] et [2].</think>\n\nLa réponse est oui[1]."
}

// MARK: - Cas nominaux

@Suite("ReasoningSegmenter — cas nominaux")
struct ReasoningSegmenterNominalTests {

    @Test("Sans aucune balise, tout est corps : c'est le cas normal", arguments: [false, true])
    func textWithoutTagsIsAllBody(isStreaming: Bool) {
        let text = "Paris est la capitale de la France[1]."
        let result = ReasoningSegmenter.segment(text, isStreaming: isStreaming)

        #expect(result == segments(body: text))
        #expect(!result.hasReasoning)
    }

    @Test("Un texte vide donne trois parties vides", arguments: [false, true])
    func emptyTextGivesEmptySegments(isStreaming: Bool) {
        #expect(ReasoningSegmenter.segment("", isStreaming: isStreaming) == segments())
    }

    @Test("Un texte fait uniquement de blancs donne un corps vide", arguments: [false, true])
    func whitespaceOnlyTextGivesEmptyBody(isStreaming: Bool) {
        #expect(ReasoningSegmenter.segment("  \n\t \n ", isStreaming: isStreaming) == segments())
    }

    @Test("Réponse Approfondie complète : raisonnement, TL;DR et corps séparés")
    func completeDeepModeAnswerIsSplitInThree() {
        let result = segmentFinal(Answers.deepMode)

        #expect(result == Answers.deepModeExpected)
        #expect(result.hasReasoning)
    }

    @Test("Bloc natif de Qwen3 : raisonnement rogné, réponse sans les sauts de ligne de tête")
    func qwenNativeThinkingBlock() {
        let text = "<think>\nOkay, l'utilisateur veut la capitale de l'Australie. La source [1] dit Canberra.\n</think>\n\n"
            + "Canberra est la capitale de l'Australie[1]."

        #expect(segmentFinal(text) == segments(
            reasoning: "Okay, l'utilisateur veut la capitale de l'Australie. La source [1] dit Canberra.",
            phase: .completed,
            body: "Canberra est la capitale de l'Australie[1]."
        ))
    }

    @Test("Bloc vide de Qwen3 en mode non-thinking : aucun encadré", arguments: [false, true])
    func emptyQwenBlockShowsNoReasoning(isStreaming: Bool) {
        let result = ReasoningSegmenter.segment(Answers.qwenEmptyBlock, isStreaming: isStreaming)

        #expect(result == segments(body: "Canberra est la capitale de l'Australie[1]."))
    }

    @Test("Deux blocs (natif Qwen3 puis celui du prompt) : un seul raisonnement, joint par une ligne vide")
    func qwenDoubleBlockIsJoinedInOneReasoning() {
        #expect(segmentFinal(Answers.qwenDoubleBlock) == Answers.qwenDoubleBlockExpected)
    }

    @Test("Les crochets de citation d'un bloc <think> y restent intacts et ne fuient pas dans le corps")
    func citationBracketsInsideThinkBlockArePreserved() {
        let text = "<think>La source [1] contredit la source [2] sur la date.</think>Les sources divergent sur la date[1][2]."
        let result = segmentFinal(text)

        #expect(result == segments(
            reasoning: "La source [1] contredit la source [2] sur la date.",
            phase: .completed,
            body: "Les sources divergent sur la date[1][2]."
        ))
        // Le corps est prêt pour l'étape suivante du rendu (tâche 1.12).
        #expect(CitationParser.parse(result.body, sourceCount: 2).citationIndices == [1, 2])
    }
}

// MARK: - Balises malformées

@Suite("ReasoningSegmenter — balises malformées")
struct ReasoningSegmenterMalformedTagTests {

    @Test("Balise fermée sans ouverture : le gabarit a ouvert le bloc, ce qui précède est du raisonnement")
    func orphanClosingTagMakesPrecedingTextReasoning() {
        #expect(segmentFinal(Answers.prefilledReasoning) == segments(
            reasoning: "Je compare les sources [1] et [2].",
            phase: .completed,
            body: "La réponse est oui[1]."
        ))
    }

    @Test("Balise fermée orpheline précédée de blancs seulement : rien à montrer")
    func orphanClosingTagAfterWhitespaceOnly() {
        #expect(segmentFinal("\n</think>\nRéponse.") == segments(body: "Réponse."))
    }

    @Test("Balise fermée orpheline après un TL;DR : simplement retirée, le texte reste corps")
    func orphanClosingTagAfterTLDRIsDropped() {
        #expect(segmentFinal("<tldr>Oui.</tldr>Le corps.</think>La suite.") == segments(
            tldr: "Oui.",
            body: "Le corps.\nLa suite."
        ))
    }

    @Test("Balise fermée orpheline après un bloc terminé : simplement retirée")
    func orphanClosingTagAfterCompletedBlockIsDropped() {
        #expect(segmentFinal("<think>Réflexion.</think>Corps</think> suite.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Corps suite."
        ))
    }

    @Test("Balises imbriquées : le PREMIER </think> ferme, l'ouverture intérieure reste du texte")
    func nestedTagsCloseOnFirstClosingTag() {
        #expect(segmentFinal("<think>A<think>B</think>C</think>D") == segments(
            reasoning: "A<think>B",
            phase: .completed,
            body: "C\nD"
        ))
    }

    @Test("Une ouverture parasite dans le raisonnement n'avale jamais la réponse")
    func spuriousInnerOpeningNeverSwallowsTheAnswer() {
        #expect(segmentFinal("<think>Je pense <think> encore.</think>La réponse est oui.") == segments(
            reasoning: "Je pense <think> encore.",
            phase: .completed,
            body: "La réponse est oui."
        ))
    }

    @Test("Plusieurs blocs : raisonnements concaténés, tronçons de corps recollés")
    func multipleBlocksAreConcatenated() {
        #expect(segmentFinal("<think>Premier.</think>Texte.<think>Second.</think>Fin.") == segments(
            reasoning: "Premier.\n\nSecond.",
            phase: .completed,
            body: "Texte.\nFin."
        ))
    }

    @Test("Plusieurs blocs, en cours de stream : le second bloc ne rouvre jamais l'encadré")
    func secondBlockNeverReopensReasoning() {
        #expect(segmentStreaming("<think>Premier.</think>Texte.<think>Second en cours") == segments(
            reasoning: "Premier.\n\nSecond en cours",
            phase: .completed,
            body: "Texte."
        ))
    }

    @Test("Bloc au milieu du texte, entre deux paragraphes : une seule ligne vide au raccord")
    func blockBetweenParagraphs() {
        #expect(segmentFinal(Answers.midTextBlock) == segments(
            reasoning: "Vérifier la population dans [1].",
            phase: .completed,
            body: "Paris est la capitale.\n\nElle compte 2,1 millions d'habitants[1]."
        ))
    }

    @Test("Bloc au milieu d'une phrase : les espaces du raccord se réduisent à une seule")
    func blockInsideASentence() {
        #expect(segmentFinal("La réponse <think>hmm, vérifier</think> est oui.") == segments(
            reasoning: "hmm, vérifier",
            phase: .completed,
            body: "La réponse est oui."
        ))
    }

    @Test("Casse différente : <THINK> et <TLDR> sont reconnus")
    func uppercaseTagsAreRecognized() {
        #expect(segmentFinal("<THINK>Réflexion.</THINK><TLDR>Résumé.</TLDR>Corps.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            tldr: "Résumé.",
            body: "Corps."
        ))
    }

    @Test("Casse mélangée, ouvrante et fermante différentes : reconnues")
    func mixedCaseTagsAreRecognized() {
        #expect(segmentFinal("<Think>Réflexion.</tHiNk>Corps.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Corps."
        ))
    }

    @Test("Espaces dans les balises : tolérés de part et d'autre du nom et de la barre")
    func spacesInsideTagsAreTolerated() {
        #expect(segmentFinal("< think >Réflexion.</ think >< tldr>Résumé.< /tldr >Corps.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            tldr: "Résumé.",
            body: "Corps."
        ))
    }

    @Test("Une tabulation dans la balise est tolérée comme une espace")
    func tabInsideTagIsTolerated() {
        #expect(segmentFinal("<think\t>Réflexion.</think>\tCorps.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Corps."
        ))
    }

    @Test("Au-delà de maxTagPadding espaces, ce n'est plus une balise")
    func paddingBeyondLimitIsNotATag() {
        let allowed = "<" + String(repeating: " ", count: ReasoningSegmenter.maxTagPadding) + "think>A</think>B"
        let tooMany = "<" + String(repeating: " ", count: ReasoningSegmenter.maxTagPadding + 1) + "think>Réflexion"

        #expect(segmentFinal(allowed) == segments(reasoning: "A", phase: .completed, body: "B"))
        #expect(segmentFinal(tooMany) == segments(body: tooMany))
    }

    @Test("Un saut de ligne à l'intérieur d'une balise la rend invalide")
    func lineBreakInsideTagIsNotATag() {
        #expect(segmentFinal("<\nthink>Réflexion") == segments(body: "<\nthink>Réflexion"))
    }

    @Test("<think> jamais refermé, flux terminé : phase interrompue, tout le texte reste consultable")
    func unclosedThinkAtEndOfStreamIsInterrupted() {
        let text = "<think>Tout le texte de la réponse, jamais refermé."

        #expect(segmentFinal(text) == segments(
            reasoning: "Tout le texte de la réponse, jamais refermé.",
            phase: .interrupted
        ))
    }

    @Test("<think> jamais refermé, flux en cours : raisonnement en cours")
    func unclosedThinkWhileStreamingIsInProgress() {
        #expect(segmentStreaming("<think>Je réfléchis encore") == segments(
            reasoning: "Je réfléchis encore",
            phase: .inProgress
        ))
    }

    @Test("Le corps écrit avant un <think> resté ouvert est conservé")
    func bodyBeforeUnclosedThinkIsKept() {
        #expect(segmentFinal("Paris est la capitale. <think>Vérifier") == segments(
            reasoning: "Vérifier",
            phase: .interrupted,
            body: "Paris est la capitale."
        ))
    }

    @Test("Balises ouvertes sans aucun contenu : jamais d'encadré, même interrompu")
    func emptyUnclosedThinkStaysAbsent() {
        #expect(segmentFinal("Réponse.<think>\n") == segments(body: "Réponse."))
    }
}

// MARK: - TL;DR

@Suite("ReasoningSegmenter — TL;DR")
struct ReasoningSegmenterTLDRTests {

    @Test("<tldr> sans <think> : TL;DR extrait, aucun raisonnement")
    func tldrWithoutThink() {
        let text = "<tldr>Canberra est la capitale de l'Australie.</tldr>\n## Détails\nCapitale depuis 1913[1]."

        #expect(segmentFinal(text) == segments(
            tldr: "Canberra est la capitale de l'Australie.",
            body: "## Détails\nCapitale depuis 1913[1]."
        ))
    }

    @Test("<tldr> non fermé : la phrase s'arrête au premier saut de ligne, la suite est corps")
    func unclosedTLDREndsAtFirstLineBreak() {
        #expect(segmentFinal(Answers.unclosedTLDR) == segments(
            tldr: "Le Mont-Blanc culmine à 4 805 mètres.",
            body: "## Altitude\nLa mesure date de 2023[1]."
        ))
    }

    @Test("<tldr> non fermé en toute fin de texte : la phrase entière est le TL;DR", arguments: [false, true])
    func unclosedTLDRAtEndOfText(isStreaming: Bool) {
        let result = ReasoningSegmenter.segment("<tldr>Une seule phrase jamais refermée", isStreaming: isStreaming)

        #expect(result == segments(tldr: "Une seule phrase jamais refermée"))
    }

    @Test("Balises <tldr> posées sur leur propre ligne : la phrase est bien isolée")
    func tldrTagsOnTheirOwnLines() {
        #expect(segmentFinal("<tldr>\nCanberra est la capitale.\n</tldr>\nDétails[1].") == segments(
            tldr: "Canberra est la capitale.",
            body: "Détails[1]."
        ))
    }

    @Test("Fin de ligne Windows : le \\r ferme aussi un TL;DR non refermé")
    func carriageReturnEndsUnclosedTLDR() {
        #expect(segmentFinal("<tldr>Oui.\r\nCorps.") == segments(tldr: "Oui.", body: "Corps."))
    }

    @Test("Un second <tldr> reste dans le corps, à sa place : seul le premier est le TL;DR")
    func secondTLDRStaysInBody() {
        #expect(segmentFinal("<tldr>Oui.</tldr>Le corps.<tldr>En bref, oui.</tldr>") == segments(
            tldr: "Oui.",
            body: "Le corps.\nEn bref, oui."
        ))
    }

    @Test("Un TL;DR vide vaut nil, jamais une carte vide")
    func emptyTLDRIsNil() {
        #expect(segmentFinal("<tldr>   </tldr>Corps.") == segments(body: "Corps."))
    }

    @Test("Un <tldr> cité dans le raisonnement y reste du texte")
    func tagsInsideReasoningAreVerbatim() {
        let text = "<think>Je dois écrire un <tldr> puis des titres ##.</think><tldr>Vrai résumé.</tldr>Corps."

        #expect(segmentFinal(text) == segments(
            reasoning: "Je dois écrire un <tldr> puis des titres ##.",
            phase: .completed,
            tldr: "Vrai résumé.",
            body: "Corps."
        ))
    }

    @Test("TL;DR avant le raisonnement : ordre inhabituel, découpage correct")
    func tldrBeforeThink() {
        #expect(segmentFinal("<tldr>Oui.</tldr><think>Réflexion.</think>Corps.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            tldr: "Oui.",
            body: "Corps."
        ))
    }
}

// MARK: - Texte ordinaire et code

@Suite("ReasoningSegmenter — texte ordinaire et code")
struct ReasoningSegmenterPlainTextTests {

    @Test("Des < ordinaires restent du texte", arguments: [false, true])
    func ordinaryLessThanSignsStayText(isStreaming: Bool) {
        let text = "Si a < b et b<c, alors a<c."

        #expect(ReasoningSegmenter.segment(text, isStreaming: isStreaming) == segments(body: text))
    }

    @Test(
        "Les balises qui ressemblent aux nôtres restent du texte",
        arguments: ["<thinking>", "<think/>", "<thinker>", "<tl>", "<t>", "<table>", "List<T>", "<tldr-bis>"]
    )
    func lookalikeTagsStayText(lookalike: String) {
        let text = "Avant \(lookalike) après."

        #expect(segmentFinal(text) == segments(body: text))
        #expect(segmentStreaming(text) == segments(body: text))
    }

    @Test("Des balises entre backticks sont du code, pas de la structure", arguments: [false, true])
    func tagsInsideInlineCodeStayText(isStreaming: Bool) {
        let text = "La balise `<think>` ouvre le raisonnement, `</think>` le ferme."

        #expect(ReasoningSegmenter.segment(text, isStreaming: isStreaming) == segments(body: text))
    }

    @Test("Un </think> entre backticks ne fait pas basculer le texte qui précède en raisonnement")
    func orphanClosingTagInsideCodeIsText() {
        let text = "Qwen3 referme sa réflexion par `</think>`, puis répond."

        #expect(segmentFinal(text) == segments(body: text))
    }

    @Test("Des balises dans un bloc de code clôturé restent du code")
    func tagsInsideFencedCodeBlockStayText() {
        let text = "Exemple :\n```\n<think>\nRéflexion\n</think>\n```\nFin."

        #expect(segmentFinal(text) == segments(body: text))
    }

    @Test("Un code refermé avant une balise ne l'empêche pas d'agir")
    func closedCodeSpanDoesNotDisableLaterTags() {
        #expect(segmentFinal("Voir `x`.<think>Réflexion.</think>Suite.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Voir `x`.\nSuite."
        ))
    }

    @Test("Dans le raisonnement, un backtick orphelin n'empêche jamais </think> de fermer")
    func backtickInsideReasoningNeverBlocksClosing() {
        #expect(segmentFinal("<think>Le code `x puis</think>La réponse.") == segments(
            reasoning: "Le code `x puis",
            phase: .completed,
            body: "La réponse."
        ))
    }

    @Test("Un backtick orphelin dans le corps affiche une balise ultérieure brute : visible, jamais caché")
    func strayBacktickInBodyShowsLaterTagRaw() {
        let text = "Il manque l`accent. <think>Réflexion</think>"

        #expect(segmentFinal(text) == segments(body: text))
    }

    @Test("Un < en toute fin de réponse est retenu pendant le stream, rendu à la fin")
    func trailingLessThanIsFlushedAtEndOfStream() {
        #expect(segmentStreaming("La valeur est <") == segments(body: "La valeur est"))
        #expect(segmentFinal("La valeur est <") == segments(body: "La valeur est <"))
    }

    @Test("Un début de balise en toute fin de réponse est retenu pendant le stream, rendu à la fin")
    func trailingPartialTagIsFlushedAtEndOfStream() {
        #expect(segmentStreaming("Réponse <thi") == segments(body: "Réponse"))
        #expect(segmentFinal("Réponse <thi") == segments(body: "Réponse <thi"))
    }

    @Test("Dans le raisonnement, seul un début de </think> est retenu")
    func holdBackInsideReasoningDependsOnContext() {
        #expect(segmentStreaming("<think>Réflexion <t") == segments(reasoning: "Réflexion <t", phase: .inProgress))
        #expect(segmentStreaming("<think>Réflexion </thi") == segments(reasoning: "Réflexion", phase: .inProgress))
    }

    @Test("Dans le TL;DR, seul un début de </tldr> est retenu")
    func holdBackInsideTLDRDependsOnContext() {
        #expect(segmentStreaming("<tldr>Oui </th") == segments(tldr: "Oui </th"))
        #expect(segmentStreaming("<tldr>Oui </tl") == segments(tldr: "Oui"))
    }

    @Test("La retenue en fin de stream est bornée par maxTagPadding")
    func holdBackIsBoundedByPadding() {
        let allowed = "Texte <" + String(repeating: " ", count: ReasoningSegmenter.maxTagPadding)
        let tooMany = "Texte <" + String(repeating: " ", count: ReasoningSegmenter.maxTagPadding + 1)

        #expect(segmentStreaming(allowed) == segments(body: "Texte"))
        #expect(segmentStreaming(tooMany) == segments(body: "Texte <"))
    }
}

// MARK: - Raccords du corps

@Suite("ReasoningSegmenter — raccords du corps")
struct ReasoningSegmenterJunctionTests {

    @Test("Tronçons collés : un saut de ligne évite un titre Markdown cassé")
    func gluedPartsAreSeparatedByALineBreak() {
        #expect(segmentFinal("Intro.<tldr>Résumé.</tldr>## Titre") == segments(
            tldr: "Résumé.",
            body: "Intro.\n## Titre"
        ))
    }

    @Test("L'indentation de la ligne qui suit le raccord est conservée")
    func indentationAfterJunctionIsKept() {
        #expect(segmentFinal("Liste :\n<think>Réflexion.</think>\n  - premier point") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Liste :\n\n  - premier point"
        ))
    }

    @Test("Beaucoup de lignes vides autour d'un bloc retiré : une seule ligne vide")
    func manyBlankLinesCollapseToOne() {
        let text = "Premier paragraphe.\n\n\n<tldr>Résumé.</tldr>\n\n\n\nSecond paragraphe."

        #expect(segmentFinal(text) == segments(
            tldr: "Résumé.",
            body: "Premier paragraphe.\n\nSecond paragraphe."
        ))
    }

    @Test("Fins de ligne Windows autour d'un bloc : normalisées")
    func windowsLineEndingsAroundBlock() {
        #expect(segmentFinal("<think>Réflexion.</think>\r\n\r\nRéponse.") == segments(
            reasoning: "Réflexion.",
            phase: .completed,
            body: "Réponse."
        ))
        #expect(segmentFinal("Intro.\r\n<think>R</think>\r\nSuite.") == segments(
            reasoning: "R",
            phase: .completed,
            body: "Intro.\n\nSuite."
        ))
    }
}

// MARK: - Streaming

@Suite("ReasoningSegmenter — streaming")
struct ReasoningSegmenterStreamingTests {

    @Test("Séquence de la mission : l'état évolue dans l'ordre, sans jamais clignoter")
    func missionSnapshotSequence() {
        let finalText = "<think>Je réfléchis</think>Réponse."
        let finalSegments = segments(reasoning: "Je réfléchis", phase: .completed, body: "Réponse.")
        let steps: [(snapshot: String, expected: ReasoningSegments)] = [
            ("<thi", segments()),
            ("<think>", segments()),
            ("<think>Je r", segments(reasoning: "Je r", phase: .inProgress)),
            ("<think>Je réfléchis</", segments(reasoning: "Je réfléchis", phase: .inProgress)),
            ("<think>Je réfléchis</think>", segments(reasoning: "Je réfléchis", phase: .completed)),
            ("<think>Je réfléchis</think>Rép", segments(reasoning: "Je réfléchis", phase: .completed, body: "Rép")),
            (finalText, finalSegments),
        ]

        for step in steps {
            #expect(segmentStreaming(step.snapshot) == step.expected, "Instantané « \(step.snapshot) »")
        }
        #expect(segmentFinal(finalText) == finalSegments)
    }

    @Test("Réponse Approfondie rejouée caractère par caractère : aucune régression, aucun fragment")
    func deepModeAnswerStreamsWithoutFlicker() {
        let history = replayStreaming(Answers.deepMode)

        #expect(history.last == Answers.deepModeExpected)
        #expect(history.contains { $0.reasoningPhase == .inProgress })
        #expect(segmentFinal(Answers.deepMode) == Answers.deepModeExpected)
    }

    @Test("Deux blocs rejoués : une fois le premier terminé, la phase ne revient jamais en arrière")
    func doubleBlockStreamsWithoutFlicker() {
        let history = replayStreaming(Answers.qwenDoubleBlock)

        #expect(history.last == Answers.qwenDoubleBlockExpected)
        let firstCompleted = history.firstIndex { $0.reasoningPhase == .completed }
        #expect(firstCompleted != nil)
        if let firstCompleted {
            #expect(history[firstCompleted...].allSatisfy { $0.reasoningPhase == .completed })
        }
    }

    @Test("Bloc vide rejoué : l'encadré n'apparaît à AUCUN instantané")
    func emptyBlockNeverShowsReasoning() {
        let history = replayStreaming(Answers.qwenEmptyBlock)

        #expect(history.allSatisfy { $0.reasoningPhase == .absent })
        #expect(history.last == segments(body: "Canberra est la capitale de l'Australie[1]."))
    }

    @Test("TL;DR non fermé rejoué : la phrase se fige au saut de ligne, le corps suit")
    func unclosedTLDRStreamsWithoutFlicker() {
        let history = replayStreaming(Answers.unclosedTLDR)

        #expect(history.last == segmentFinal(Answers.unclosedTLDR))
    }

    @Test("Bloc au milieu du texte rejoué : le raccord ne réécrit jamais le corps déjà affiché")
    func midTextBlockStreamsWithoutFlicker() {
        let history = replayStreaming(Answers.midTextBlock)

        #expect(history.last == segmentFinal(Answers.midTextBlock))
    }

    @Test("</think> orphelin : une seule bascule du corps vers le raisonnement, puis préfixe stable")
    func orphanClosingTagSwitchesOnceThenStaysStable() {
        #expect(segmentStreaming("Je compare les sources") == segments(body: "Je compare les sources"))
        #expect(segmentStreaming("Je compare les sources [1] et [2].</thi") == segments(
            body: "Je compare les sources [1] et [2]."
        ))
        #expect(segmentStreaming("Je compare les sources [1] et [2].</think>") == segments(
            reasoning: "Je compare les sources [1] et [2].",
            phase: .completed
        ))

        // Après la bascule, retour aux garanties ordinaires.
        let switchLength = "Je compare les sources [1] et [2].</think>".count
        let history = replayStreaming(Answers.prefilledReasoning, from: switchLength)
        #expect(history.last == segmentFinal(Answers.prefilledReasoning))
    }

    @Test("Fin du flux : un raisonnement en cours devient interrompu, avec le même texte")
    func endOfStreamTurnsInProgressIntoInterrupted() {
        let text = "<think>Réflexion en cours"

        #expect(segmentStreaming(text).reasoningPhase == .inProgress)
        #expect(segmentFinal(text) == segments(reasoning: "Réflexion en cours", phase: .interrupted))
    }

    @Test("Un fragment retenu se résout à l'instantané suivant, sans jamais avoir été affiché")
    func heldBackFragmentResolvesOnNextSnapshot() {
        #expect(segmentStreaming("Réponse <th") == segments(body: "Réponse"))
        #expect(segmentStreaming("Réponse <the") == segments(body: "Réponse <the"))
        #expect(segmentStreaming("Réponse <think") == segments(body: "Réponse"))
        #expect(segmentStreaming("Réponse <think>Hmm") == segments(
            reasoning: "Hmm",
            phase: .inProgress,
            body: "Réponse"
        ))
    }
}

// MARK: - Coût

@Suite("ReasoningSegmenter — coût")
struct ReasoningSegmenterCostTests {

    @Test("Des milliers de < consécutifs : tout reste du texte, seul le dernier est retenu en stream")
    func manyConsecutiveLessThanSigns() {
        let text = String(repeating: "<", count: 100_000)

        #expect(segmentFinal(text) == segments(body: text))
        #expect(segmentStreaming(text) == segments(body: String(repeating: "<", count: 99_999)))
    }

    @Test("Des milliers de débuts de balise avortés : tout reste du texte")
    func manyAbortedTagStarts() {
        let text = String(repeating: "<thi", count: 50_000)

        #expect(segmentFinal(text) == segments(body: text))
        #expect(segmentStreaming(text) == segments(body: String(text.dropLast(4))))
    }

    @Test("Des milliers de < suivis d'une espace : aucun balayage ne déborde sur le suivant")
    func manyPaddedLessThanSigns() {
        let text = String(repeating: "< ", count: 50_000) + "fin"

        #expect(segmentFinal(text) == segments(body: text))
    }

    /// Une réponse de ~600 Ko pleine de balises. Un coût quadratique y
    /// demanderait des heures ; la borne est volontairement très large pour
    /// ne jamais échouer par simple lenteur de la machine de test.
    @Test("Une très longue réponse pleine de balises se découpe en temps linéaire")
    func longAnswerIsSegmentedInLinearTime() {
        let text = String(repeating: Answers.deepMode + "\n\n", count: 2_000)
        var result = segments()

        let elapsed = ContinuousClock().measure {
            result = segmentFinal(text)
        }

        #expect(elapsed < .seconds(5))
        #expect(result.reasoningPhase == .completed)
        #expect(result.tldr == Answers.deepModeExpected.tldr)
    }
}
