//
//  ResponseStructureValidatorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 18/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Le validateur teste ses PROPRES règles sur des textes fixes, écrits à la
/// main : c'est la seule façon d'être déterministe, puisqu'une vraie réponse
/// de LLM ne l'est pas (voir la doc de `ResponseStructureValidator`). Aucun
/// mock n'est nécessaire — tout est pur.
@MainActor
@Suite("ResponseStructureValidator")
struct ResponseStructureValidatorTests {

    private let validator = ResponseStructureValidator()

    // MARK: - Textes conformes (aucune violation)

    @Test("Mode Rapide : 2 phrases citées, aucune violation")
    func cleanQuickResponse() {
        let text = "Paris est la capitale de la France[1]. La ville compte plus de deux millions d'habitants[2]."

        let report = validator.validate(text, mode: .quick, citableSourceCount: 2)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Approfondi détaillé : <think>, <tldr>, sections, une Conclusion de 2 phrases — aucune violation")
    func cleanDeepResponse() {
        let report = validator.validate(
            Self.conformingDeepResponse,
            mode: .deep,
            complexity: .full,
            citableSourceCount: 2
        )

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Fiable : réponse directe avec marqueur de non-confirmation — aucune violation")
    func cleanReliableResponse() {
        let text = """
        Le taux de conversion mesuré est de 6 %[1]. Le rendement théorique maximal n'est pas précisé \
        \(PromptTemplates.unsupportedClaimMarker).
        """

        let report = validator.validate(text, mode: .reliable, citableSourceCount: 1)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    // MARK: - Citations

    @Test("Aucune citation alors que le contexte en contenait : missingCitation")
    func missingCitationIsReported() {
        let report = validator.validate(
            "Paris est la capitale de la France. La ville est très peuplée.",
            mode: .quick,
            citableSourceCount: 2
        )

        #expect(report.contains(.missingCitation))
    }

    @Test("Contexte vide (0 document) : l'exigence de citation est levée, rien à citer")
    func noCitationRequiredWhenContextIsEmpty() {
        let report = validator.validate(
            "Bonjour, je peux t'aider à chercher quelque chose.",
            mode: .quick,
            citableSourceCount: 0
        )

        #expect(!report.contains(.missingCitation))
        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Fiable sans source : l'avertissement imposé par le prompt ne compte pas comme une violation")
    func reliableWarningWithoutSourcesIsNotAViolation() {
        let text = """
        \(PromptTemplates.unverifiedSourcesWarning)
        La photosynthèse transforme la lumière en énergie chimique \(PromptTemplates.unsupportedClaimMarker).
        """

        let report = validator.validate(text, mode: .reliable, citableSourceCount: 0)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("La réponse « aucune information fiable » imposée par le prompt est exemptée de citation")
    func mandatedNoInformationAnswerIsExempt() {
        let report = validator.validate(
            PromptTemplates.noRelevantInformationAnswer,
            mode: .deep,
            complexity: .concise,
            citableSourceCount: 3
        )

        #expect(!report.contains(.missingCitation))
    }

    @Test("La même réponse encadrée de guillemets par le modèle reste exemptée")
    func quotedNoInformationAnswerIsExempt() {
        let report = validator.validate(
            "« \(PromptTemplates.noRelevantInformationAnswer) »",
            mode: .quick,
            citableSourceCount: 3
        )

        #expect(!report.contains(.missingCitation))
    }

    @Test("Citation [0] : numérotation invalide, la numérotation du contexte commence à 1")
    func zeroCitationIsMalformed() {
        let report = validator.validate("Paris est la capitale[0].", mode: .quick, citableSourceCount: 2)

        #expect(report.contains(.malformedCitation))
        #expect(report.violations.first { $0.kind == .malformedCitation }?.excerpt == "[0]")
    }

    @Test("Citation [abc] : contenu non numérique entre crochets, impossible à relier à une source")
    func alphabeticCitationIsMalformed() {
        let report = validator.validate("Paris est la capitale[abc].", mode: .quick, citableSourceCount: 2)

        #expect(report.contains(.malformedCitation))
        #expect(report.violations.first { $0.kind == .malformedCitation }?.excerpt == "[abc]")
    }

    @Test("Citation [1 non refermée : signalée telle qu'elle apparaît")
    func unclosedCitationIsMalformed() {
        let report = validator.validate("Paris est la capitale[1", mode: .quick, citableSourceCount: 2)

        #expect(report.contains(.malformedCitation))
        #expect(report.violations.first { $0.kind == .malformedCitation }?.excerpt == "[1")
    }

    @Test("Citation [1,2] : le prompt impose [1][2], la virgule est une vraie faute")
    func commaSeparatedCitationIsMalformed() {
        let scan = ResponseStructureValidator.scanCitations(in: "Paris est un pôle culturel[1,2].")

        #expect(scan.validNumbers.isEmpty)
        #expect(scan.malformedTokens == ["[1,2]"])
    }

    @Test("[1][2] : deux citations valides, aucune faute")
    func multipleCitationsAreValid() {
        let scan = ResponseStructureValidator.scanCitations(in: "Paris est un pôle culturel[1][2].")

        #expect(scan.validNumbers == [1, 2])
        #expect(scan.malformedTokens.isEmpty)
    }

    @Test("Un lien markdown [texte](url) n'est pas une tentative de citation")
    func markdownLinkIsNotACitation() {
        let scan = ResponseStructureValidator.scanCitations(in: "Voir [la documentation](https://exemple.fr) et ce fait[1].")

        #expect(scan.validNumbers == [1])
        #expect(scan.malformedTokens.isEmpty)
    }

    @Test("Une insertion éditoriale [...] n'est pas une tentative de citation")
    func editorialEllipsisIsNotACitation() {
        let scan = ResponseStructureValidator.scanCitations(in: "La citation est tronquée [...] puis reprend[1].")

        #expect(scan.validNumbers == [1])
        #expect(scan.malformedTokens.isEmpty)
    }

    @Test("Une parenthèse de prose entre crochets, trop longue pour être une citation, est ignorée")
    func longBracketedProseIsIgnored() {
        let scan = ResponseStructureValidator.scanCitations(in: "Note [voir la remarque en bas de page] puis le fait[1].")

        #expect(scan.validNumbers == [1])
        #expect(scan.malformedTokens.isEmpty)
    }

    @Test("Citation dont le numéro dépasse le nombre de documents : numéro inventé")
    func outOfRangeCitationIsReported() {
        let report = validator.validate("Paris est la capitale[5].", mode: .quick, citableSourceCount: 2)

        #expect(report.contains(.citationOutOfRange))
        #expect(report.violations.first { $0.kind == .citationOutOfRange }?.excerpt == "[5]")
    }

    @Test("Nombre de documents inconnu (nil) : les numéros inventés ne sont plus détectables, les autres règles tiennent")
    func unknownSourceCountDisablesOnlyRangeCheck() {
        let report = validator.validate("Paris est la capitale[5].", mode: .quick, citableSourceCount: nil)

        #expect(!report.contains(.citationOutOfRange))
        #expect(!report.contains(.missingCitation))
        #expect(report.isClean, "\(report.debugSummary)")
    }

    // MARK: - Formulations bannies

    @Test(
        "Chaque formulation bannie par le prompt writer est détectée",
        arguments: PromptTemplates.allBannedPhrases
    )
    func everyBannedPhraseIsDetected(phrase: String) {
        let report = validator.validate(
            "Paris est la capitale[1]. \(phrase) la ville continue de croître[1].",
            mode: .deep,
            complexity: .concise,
            citableSourceCount: 1
        )

        #expect(report.contains(.bannedPhrase))
        #expect(report.violations.contains { $0.excerpt == phrase })
    }

    @Test("Détection insensible à la casse et aux accents : « En Resume » est attrapé comme « en résumé »")
    func bannedPhraseDetectionFoldsCaseAndDiacritics() {
        let report = validator.validate("En Resume, Paris est la capitale[1].", mode: .quick, citableSourceCount: 1)

        #expect(report.contains(.bannedPhrase))
    }

    @Test("Un texte sans formulation bannie n'en signale aucune")
    func cleanTextHasNoBannedPhrase() {
        let report = validator.validate("Paris est la capitale de la France[1].", mode: .quick, citableSourceCount: 1)

        #expect(!report.contains(.bannedPhrase))
    }

    // MARK: - Longueur de la conclusion

    @Test("Conclusion d'une seule phrase : conforme")
    func oneSentenceConclusionIsAccepted() {
        let text = """
        ## Bilan
        Le rendement plafonne bien en dessous du photovoltaïque[1].
        """

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(!report.contains(.conclusionTooLong))
    }

    @Test("Conclusion de deux phrases : conforme, c'est exactement la limite")
    func twoSentenceConclusionIsAccepted() {
        let text = """
        ## Bilan
        Le rendement plafonne bien en dessous du photovoltaïque[1]. Cela oriente la recherche vers des hybrides.
        """

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(!report.contains(.conclusionTooLong))
    }

    @Test("Conclusion de trois phrases : violation, avec le compte exact dans le détail")
    func threeSentenceConclusionIsReported() {
        let text = """
        ## Bilan
        Le rendement plafonne[1]. Cela oriente la recherche. Les hybrides sont la piste principale.
        """

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(report.contains(.conclusionTooLong))
        #expect(report.violations.first { $0.kind == .conclusionTooLong }?.detail.contains("3 phrases") == true)
    }

    @Test("Sans aucun titre, il n'y a pas de conclusion analysable : la règle ne s'applique pas")
    func conclusionRuleNeedsAHeading() {
        let text = "Une phrase[1]. Deux phrases. Trois phrases. Quatre phrases."

        let report = validator.validate(text, mode: .reliable, citableSourceCount: 1)

        #expect(!report.contains(.conclusionTooLong))
    }

    // MARK: - Mode Approfondi

    @Test("Mode Approfondi, texte long sans aucun titre : missingHeadings")
    func longDeepResponseWithoutHeadingsIsReported() {
        let text = Array(repeating: "mot", count: 200).joined(separator: " ") + " [1]."

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(report.contains(.missingHeadings))
    }

    @Test("Mode Approfondi, texte court sans titre : pas de violation, les sources étaient trop minces")
    func shortDeepResponseWithoutHeadingsIsAccepted() {
        let text = "Les sources disponibles ne donnent qu'un chiffre : le rendement est de 6 %[1]."

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(!report.contains(.missingHeadings))
    }

    @Test("Mode Approfondi : deux titres de conclusion, le prompt en impose exactement un")
    func duplicateConclusionHeadingIsReported() {
        let text = """
        ## Principe
        Les plantes captent la lumière[1].

        ## Conclusion
        Le rendement plafonne[1].

        ## Conclusion finale
        Les hybrides sont la piste.
        """

        let report = validator.validate(text, mode: .deep, complexity: .concise, citableSourceCount: 1)

        #expect(report.contains(.duplicateConclusionHeading))
    }

    @Test("Mode Approfondi détaillé : blocs <think> et <tldr> absents, tous deux signalés")
    func missingReasoningBlocksAreReported() {
        let text = """
        ## Principe
        Les plantes captent la lumière[1].

        ## Conclusion
        Le rendement plafonne[1].
        """

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 1)

        #expect(report.contains(.missingReasoningBlock))
        #expect(report.contains(.missingTLDRBlock))
    }

    @Test("Balise <think> ouverte et jamais refermée : elle s'afficherait brute dans la réponse")
    func unclosedThinkBlockIsReported() {
        let text = """
        <think>Je réfléchis à la question.
        <tldr>La photosynthèse convertit la lumière.</tldr>

        ## Principe
        Les plantes captent la lumière[1].
        """

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 1)

        #expect(report.contains(.unclosedReasoningBlock))
        #expect(!report.contains(.missingReasoningBlock))
    }

    @Test("Mode Approfondi concis : les blocs <think>/<tldr> sont INTERDITS, pas exigés")
    func conciseDeepForbidsReasoningBlocks() {
        let report = validator.validate(
            Self.conformingDeepResponse,
            mode: .deep,
            complexity: .concise,
            citableSourceCount: 2
        )

        #expect(report.count(of: .forbiddenReasoningBlock) == 2)
        #expect(!report.contains(.missingReasoningBlock))
        #expect(!report.contains(.missingTLDRBlock))
    }

    // MARK: - Mode Rapide

    @Test("Mode Rapide : 4 phrases, au-dessus de la limite de 3")
    func quickModeTooLongIsReported() {
        let text = "Une phrase[1]. Deux phrases. Trois phrases. Quatre phrases."

        let report = validator.validate(text, mode: .quick, citableSourceCount: 1)

        #expect(report.contains(.quickModeTooLong))
        #expect(report.violations.first { $0.kind == .quickModeTooLong }?.detail.contains("4 phrases") == true)
    }

    @Test("Mode Rapide : exactement 3 phrases, la limite est atteinte mais pas dépassée")
    func quickModeThreeSentencesIsAccepted() {
        let text = "Une phrase[1]. Deux phrases. Trois phrases."

        let report = validator.validate(text, mode: .quick, citableSourceCount: 1)

        #expect(!report.contains(.quickModeTooLong))
    }

    @Test("Mode Rapide : un bloc <think> est interdit")
    func quickModeForbidsThinkBlock() {
        let text = "<think>Je réfléchis.</think> Paris est la capitale[1]."

        let report = validator.validate(text, mode: .quick, citableSourceCount: 1)

        #expect(report.contains(.forbiddenReasoningBlock))
    }

    @Test("Mode Fiable : un bloc <tldr> est interdit")
    func reliableModeForbidsTLDRBlock() {
        let text = "<tldr>Résumé.</tldr> Paris est la capitale[1]."

        let report = validator.validate(text, mode: .reliable, citableSourceCount: 1)

        #expect(report.contains(.forbiddenReasoningBlock))
    }

    // MARK: - Texte vide

    @Test("Texte vide : une seule violation, les autres règles ne sont pas évaluées en cascade")
    func emptyTextReportsOnlyEmptyResponse() {
        let report = validator.validate("   \n  \t ", mode: .deep, complexity: .full, citableSourceCount: 3)

        #expect(report.violations.map(\.kind) == [.emptyResponse])
    }

    // MARK: - Découpage en phrases (le piège du français)

    @Test("« M. Dupont a dit... 3.5 % environ. » ne fait pas 3 phrases mais 1")
    func abbreviationsAndDecimalsDoNotSplitSentences() {
        #expect(ResponseStructureValidator.sentences(in: "M. Dupont a dit... 3.5 % environ.").count == 1)
    }

    /// Ce test ne dépend PAS du découpage réel de `NLTokenizer` : il alimente
    /// directement la passe de recollage avec les fragments que le tokenizer
    /// produirait dans le pire des cas. Si Apple change son découpage d'une
    /// version d'OS à l'autre, c'est cette garantie-là qui doit tenir.
    @Test("La passe de recollage réunit les faux découpages, quels que soient les fragments reçus")
    func mergePassRejoinsFalseBreaks() {
        let merged = ResponseStructureValidator.mergeFalseSentenceBreaks(["M.", "Dupont a dit...", "3,5 % environ."])

        #expect(merged.count == 1)
        #expect(merged.first == "M. Dupont a dit... 3,5 % environ.")
    }

    @Test("Une initiale isolée ne termine pas une phrase")
    func initialDoesNotEndASentence() {
        #expect(ResponseStructureValidator.continuesOnNextFragment("Publié par J."))
    }

    @Test("Un nombre suivi d'un point ne termine pas une phrase")
    func decimalDoesNotEndASentence() {
        #expect(ResponseStructureValidator.continuesOnNextFragment("Le taux est de 3."))
    }

    @Test("Des points de suspension ne terminent pas une phrase de façon sûre")
    func ellipsisDoesNotEndASentence() {
        #expect(ResponseStructureValidator.continuesOnNextFragment("Il a hésité..."))
        #expect(ResponseStructureValidator.continuesOnNextFragment("Il a hésité…"))
    }

    @Test("Une phrase ordinaire termine bien : aucun recollage abusif")
    func ordinarySentenceEnds() {
        #expect(!ResponseStructureValidator.continuesOnNextFragment("Paris est la capitale."))
        #expect(!ResponseStructureValidator.continuesOnNextFragment("Paris est la capitale[1]."))
    }

    @Test("Deux phrases citées normalement comptent bien pour deux")
    func normalSentencesAreCountedIndividually() {
        let text = "Paris est la capitale[1]. Elle compte deux millions d'habitants[2]."

        #expect(ResponseStructureValidator.sentences(in: text).count == 2)
    }

    @Test("Texte vide : zéro phrase, jamais un fragment vide")
    func emptyTextHasNoSentence() {
        #expect(ResponseStructureValidator.sentences(in: "   ").isEmpty)
    }

    // MARK: - Utilitaires d'analyse

    @Test("Seuls les titres de niveau 2 ou plus sont reconnus, dièses retirés")
    func headingsAreExtractedWithoutHashes() {
        let text = """
        # Titre principal interdit
        ## Principe
        Texte.
        ### Détail
        """

        #expect(ResponseStructureValidator.headings(in: text) == ["Principe", "Détail"])
    }

    @Test("Le texte après le dernier titre est isolé ; nil si le texte n'a aucun titre")
    func textAfterLastHeadingIsIsolated() {
        let text = """
        ## Principe
        Un fait[1].

        ## Bilan
        Une conclusion[1].
        """

        #expect(ResponseStructureValidator.textAfterLastHeading(in: text) == "Une conclusion[1].")
        #expect(ResponseStructureValidator.textAfterLastHeading(in: "Aucun titre ici[1].") == nil)
    }

    @Test("Le compte de mots ignore les retours à la ligne et les espaces multiples")
    func wordCountIgnoresWhitespace() {
        #expect(ResponseStructureValidator.wordCount(of: "un  deux\ntrois\t quatre") == 4)
    }

    // MARK: - Rapport

    @Test("Le rapport porte le mode et la verbosité analysés, pour rester interprétable plus tard")
    func reportCarriesItsContext() {
        let report = validator.validate("Texte[1].", mode: .reliable, complexity: .concise, citableSourceCount: 1)

        #expect(report.mode == .reliable)
        #expect(report.complexity == .concise)
    }

    @Test("Le résumé de debug liste chaque violation avec sa catégorie et son extrait")
    func debugSummaryListsViolations() {
        let report = validator.validate("En résumé, rien n'est cité.", mode: .quick, citableSourceCount: 2)

        #expect(report.debugSummary.contains("missingCitation"))
        #expect(report.debugSummary.contains("bannedPhrase"))
        #expect(report.debugSummary.contains("en résumé"))
    }

    @Test("Le résumé de debug d'un texte conforme le dit explicitement")
    func debugSummaryOfCleanReport() {
        let report = validator.validate("Paris est la capitale[1].", mode: .quick, citableSourceCount: 1)

        #expect(report.debugSummary.contains("Structure conforme"))
    }

    @Test("Les catégories de violation ont des identifiants bruts distincts et non vides")
    func violationKindsAreWellFormed() {
        let rawValues = ResponseStructureViolation.Kind.allCases.map(\.rawValue)

        #expect(rawValues.allSatisfy { !$0.isEmpty })
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("Les formulations bannies contrôlées sont injectables : une liste vide désactive la règle")
    func bannedPhraseListIsInjectable() {
        let permissive = ResponseStructureValidator(bannedPhrases: [])

        let report = permissive.validate("En résumé, Paris est la capitale[1].", mode: .quick, citableSourceCount: 1)

        #expect(!report.contains(.bannedPhrase))
    }

    // MARK: - Fixtures

    /// Réponse de référence en mode Approfondi détaillé : elle respecte
    /// toutes les consignes de `PromptTemplates.modeSection(for: .deep,
    /// complexity: .full)`. Elle sert deux fois — une fois pour prouver
    /// qu'elle ne déclenche rien en `.full`, une fois pour prouver que les
    /// MÊMES blocs deviennent des violations en `.concise`.
    private static let conformingDeepResponse = """
    <think>La question porte sur le rendement de la photosynthèse. La source 1 donne le principe, la source 2 le chiffre. Les deux ne couvrent pas les variantes artificielles.</think>
    <tldr>La photosynthèse convertit la lumière en énergie chimique avec un rendement réel d'environ 6 %.</tldr>

    ## Principe
    Les plantes captent la lumière pour produire des sucres[1].

    ## Rendement
    Le rendement réel plafonne autour de 6 %[2].

    ## Conclusion
    Ce plafond situe la photosynthèse bien en dessous du photovoltaïque[2]. Cela explique l'intérêt actuel pour les systèmes hybrides.
    """
}

// MARK: - Blocs <think>/<tldr> : alignement sur ReasoningSegmenter (I1b)

/// Chaque test ci-dessous échoue sur le validateur d'avant I1b, qui cherchait
/// les balises exactes `"<think>"`/`"</think>"`/`"<tldr>"`/`"</tldr>"` dans le
/// texte brut, là où l'affichage (`ReasoningSegmenter`) tolère la casse et
/// les espaces, ignore les balises entre backticks et les blocs vides.
extension ResponseStructureValidatorTests {
    @Test("Mode Rapide : <THINK> en majuscules est un bloc interdit — il s'affiche comme un encadré de raisonnement")
    func uppercaseThinkIsForbiddenInQuickMode() {
        let report = validator.validate("<THINK>Je réfléchis.</THINK> Paris est la capitale[1].", mode: .quick, citableSourceCount: 1)

        #expect(report.count(of: .forbiddenReasoningBlock) == 1)
    }

    @Test("Mode Fiable : < think > et </ think > avec espaces forment un bloc interdit, comme à l'affichage")
    func paddedThinkIsForbiddenInReliableMode() {
        let report = validator.validate("< think >Je réfléchis.</ think > Paris est la capitale[1].", mode: .reliable, citableSourceCount: 1)

        #expect(report.contains(.forbiddenReasoningBlock))
    }

    @Test("Mode Rapide : une réponse qui EXPLIQUE la balise `<think>` entre backticks est conforme (faux positif avant)")
    func backtickedThinkTagIsPlainText() {
        let text = "Qwen3 écrit son raisonnement dans une balise `<think>` avant de répondre[1]."

        let report = validator.validate(text, mode: .quick, citableSourceCount: 1)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Rapide : le bloc vide de Qwen3 en mode non-thinking n'est pas signalé — aucun encadré ne s'affiche")
    func emptyThinkBlockIsNotReported() {
        let report = validator.validate("<think>\n\n</think>\nParis est la capitale[1].", mode: .quick, citableSourceCount: 1)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Approfondi détaillé : <THINK> et <TLDR> en majuscules satisfont l'exigence — rien d'« absent »")
    func uppercaseBlocksSatisfyDeepMode() {
        let text = Self.conformingDeepResponse
            .replacingOccurrences(of: "<think>", with: "<THINK>")
            .replacingOccurrences(of: "</think>", with: "</THINK>")
            .replacingOccurrences(of: "<tldr>", with: "<TLDR>")
            .replacingOccurrences(of: "</tldr>", with: "</TLDR>")

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 2)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Approfondi détaillé : </think> orphelin en tête (gabarits Qwen Thinking-2507, DeepSeek-R1) compte comme un raisonnement")
    func orphanClosingThinkCountsAsReasoning() {
        let text = Self.conformingDeepResponse.replacingOccurrences(of: "<think>", with: "")

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 2)

        #expect(report.isClean, "\(report.debugSummary)")
    }

    @Test("Mode Approfondi détaillé : <Think> (casse mixte) jamais refermé -> unclosedReasoningBlock seul, sans « absent » en cascade")
    func mixedCaseUnclosedThinkIsReportedOnce() {
        let text = "<Think>Je réfléchis à la question.\n\n## Principe\nLes plantes captent la lumière[1]."

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 1)

        #expect(report.contains(.unclosedReasoningBlock))
        #expect(!report.contains(.missingReasoningBlock))
        #expect(!report.contains(.missingTLDRBlock))
    }

    @Test("Mode Approfondi détaillé : <tldr> refermé par un saut de ligne s'affiche correctement — pas « non refermé »")
    func tldrClosedByLineBreakIsNotUnclosed() {
        let text = Self.conformingDeepResponse.replacingOccurrences(of: "</tldr>", with: "")

        let report = validator.validate(text, mode: .deep, complexity: .full, citableSourceCount: 2)

        #expect(report.isClean, "\(report.debugSummary)")
    }
}
