//
//  AgenticResearchComparisonTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Banc de comparaison de la recherche 2.4 (spec §7) : boucle actuelle (côté `classic`) contre enquêteur
/// DynamicProfile (côté `agentic`), avec le VRAI `SearchOrchestrator`, le vrai Apple Intelligence et le vrai
/// réseau, AUCUNE clé BYOK. Seul `agenticResearcher` change entre les deux côtés. Par question et par mode : 2
/// passages, A puis B au premier, B puis A au second.
///
/// JAMAIS dans la suite normale : désactivé sans `TEST_RUNNER_TRIVA_EVAL=1` (et Apple Intelligence disponible).
/// Variables (préfixe `TEST_RUNNER_` côté `xcodebuild`) :
/// - `TRIVA_EVAL_OUT` : dossier des JSON et de `resume.md` ; sous Mac l'app est en bac à sable : repli sur le
///   dossier temporaire (le chemin est affiché, ligne `EVAL|dossier=`) ;
/// - `TRIVA_EVAL_RANGE` : indices de 0 à 19 du jeu de questions, « 0-9 » ou « 10-19 » (lots de 10 : le
///   simulateur est instable en session longue). Une exécution déjà écrite est sautée : on peut relancer.
/// Le banc ne juge pas : une mauvaise réponse est une donnée, pas un échec. Les JSON ne contiennent jamais
/// d'hôte d'instance SearXNG (`AgenticEvalScrubber`), jamais de clé.
nonisolated enum AgenticEvalGate {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { environment["TRIVA_EVAL"] == "1" && SystemLanguageModel.default.isAvailable }
    static var range: String? { environment["TRIVA_EVAL_RANGE"] }
}

/// Un côté de la comparaison : `classic` = pas d'enquêteur, `agentic` = enquêteur Apple Intelligence.
nonisolated enum AgenticEvalSide: String, Sendable {
    case classic
    case agentic
}

@Suite("Banc de comparaison 2.4 (manuel)", .serialized, .enabled(if: AgenticEvalGate.enabled))
@MainActor
struct AgenticResearchComparisonTests {
    @Test("Une question, tous ses modes, deux passages A/B puis B/A", arguments: AgenticEvalQuestions.selected(range: AgenticEvalGate.range))
    func compare(question: AgenticEvalQuestion) async {
        guard let world = AgenticEvalWorld.shared else {
            Issue.record("Aucune instance SearXNG chargée : le banc ne peut pas garantir la confidentialité de ses sorties.")
            return
        }
        for mode in question.modes {
            for pass in 1...2 {
                let order: [AgenticEvalSide] = pass == 1 ? [.classic, .agentic] : [.agentic, .classic]
                for (index, side) in order.enumerated() {
                    await world.runAndWrite(question: question, mode: mode, pass: pass, side: side, position: index + 1)
                }
            }
        }
        world.writeSummary()
    }
}
