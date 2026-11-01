//
//  WidgetExecutorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 17/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures

/// Provider IA factice : aucun widget de ce fichier ne l'appelle réellement
/// (l'exécuteur ne fait que le transporter jusqu'aux widgets), il n'a donc
/// qu'à exister et à satisfaire `AIGenerating`. `struct` plutôt que `class`
/// pour rester trivialement `Sendable` — l'entrée traverse le `TaskGroup`.
private struct StubAIProvider: AIGenerating {
    func generate(prompt: String) async throws -> String { "{}" }
}

/// Donnée typée factice, pour vérifier qu'un `payload` traverse l'exécuteur
/// sans perdre son type réel.
private struct StubPayload: SearchWidgetPayload, Equatable {
    let value: String
}

private enum StubWidgetError: Error, Sendable {
    case boom
}

/// Compte les exécutions réelles, pour prouver qu'un widget non éligible
/// n'est jamais lancé (et pas seulement que sa sortie est absente).
private actor ExecutionCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// Mesure le nombre maximum de widgets présents SIMULTANÉMENT dans leur
/// exécution — la seule preuve directe du parallélisme qui ne dépende pas
/// d'une mesure de durée, toujours fragile sur une machine chargée.
private actor ConcurrencyProbe {
    private var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func leave() {
        current -= 1
    }
}

private struct StubWidget: SearchWidget {
    enum Behavior: Sendable {
        /// Sortie immédiate.
        case output(llmContext: String, payload: String?)
        /// Rien à afficher — cas nominal, pas une erreur.
        case nothing
        case failure
        /// Attend avant de répondre : sert à dépasser le budget de temps.
        case sleep(Duration)
        /// Signale son entrée/sortie à la sonde de parallélisme.
        case probed(ConcurrencyProbe, hold: Duration)
    }

    let kind: SearchWidgetKind
    let trigger: @Sendable (QueryClassification) -> Bool
    let behavior: Behavior
    let counter: ExecutionCounter?

    init(
        kind: SearchWidgetKind,
        trigger: @escaping @Sendable (QueryClassification) -> Bool,
        behavior: Behavior,
        counter: ExecutionCounter? = nil
    ) {
        self.kind = kind
        self.trigger = trigger
        self.behavior = behavior
        self.counter = counter
    }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        trigger(classification)
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        await counter?.record()

        switch behavior {
        case .output(let llmContext, let payload):
            return SearchWidgetOutput(
                kind: kind,
                llmContext: llmContext,
                payload: payload.map { StubPayload(value: $0) }
            )
        case .nothing:
            return nil
        case .failure:
            throw StubWidgetError.boom
        case .sleep(let duration):
            try await Task.sleep(for: duration)
            return SearchWidgetOutput(kind: kind, llmContext: "tardif")
        case .probed(let probe, let hold):
            await probe.enter()
            try? await Task.sleep(for: hold)
            await probe.leave()
            return SearchWidgetOutput(kind: kind, llmContext: "parallèle")
        }
    }
}

// MARK: - Fabriques

private func makeClassification(
    skipSearch: Bool = false,
    personalSearch: Bool = false,
    academicSearch: Bool = false,
    discussionSearch: Bool = false,
    weather: Bool = false,
    stock: Bool = false,
    calculation: Bool = false
) -> QueryClassification {
    QueryClassification(
        skipSearch: skipSearch,
        personalSearch: personalSearch,
        academicSearch: academicSearch,
        discussionSearch: discussionSearch,
        showWeatherWidget: weather,
        showStockWidget: stock,
        showCalculationWidget: calculation,
        standaloneFollowUp: "Quel temps fait-il à Paris ?"
    )
}

private func makeInput(_ classification: QueryClassification) -> SearchWidgetInput {
    SearchWidgetInput(
        query: "et à Paris ?",
        chatHistory: [ClassifierChatMessage(role: .user, content: "météo")],
        classification: classification,
        aiProvider: StubAIProvider()
    )
}

/// Les deux widgets « contractuels » : exactement le couplage que les
/// services météo et calcul réels devront adopter (`showWeatherWidget` /
/// `showCalculationWidget`), pour que les tests de sélection reflètent
/// l'assemblage réel et pas un montage de test arbitraire.
private func makeContractualWidgets() -> [any SearchWidget] {
    [
        StubWidget(
            kind: .weather,
            trigger: { $0.showWeatherWidget },
            behavior: .output(llmContext: "Météo Paris : 18 °C", payload: "paris")
        ),
        StubWidget(
            kind: .calculation,
            trigger: { $0.showCalculationWidget },
            behavior: .output(llmContext: "15 % de 240 = 36", payload: "36")
        )
    ]
}

// Pas de `@MainActor` sur cette suite, contrairement aux autres : deux de ses
// tests mesurent du TEMPS RÉEL écoulé pour prouver que le `TaskGroup` est bien
// annulé au lieu d'attendre sa minuterie. Isolée au main actor, la suite
// partagerait un exécuteur sérialisé avec les ~70 autres suites et la mesure
// inclurait leur attente : les deux tests échouaient dans la suite complète
// alors qu'ils passaient seuls (18/18). Les types manipulés ici
// (`SearchWidgetInput`, `SearchWidgetOutput`, `QueryClassification`) sont
// `nonisolated`, l'annotation n'est donc pas nécessaire pour compiler.
@Suite("WidgetExecutor")
struct WidgetExecutorTests {
    // MARK: - Sélection

    @Test("Aucun drapeau de widget : rien n'est exécuté, ni sortie ni échec")
    func noEligibleWidgetProducesEmptyReport() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(skipSearch: true, academicSearch: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(report.combinedLLMContext.isEmpty)
    }

    @Test("showWeatherWidget déclenche le widget météo, et lui seul")
    func weatherFlagRunsOnlyWeatherWidget() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(weather: true)))

        #expect(report.outputs.map(\.kind) == [.weather])
        #expect(report.failures.isEmpty)
    }

    @Test("showCalculationWidget déclenche le widget calcul, et lui seul")
    func calculationFlagRunsOnlyCalculationWidget() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(calculation: true)))

        #expect(report.outputs.map(\.kind) == [.calculation])
        #expect(report.failures.isEmpty)
    }

    @Test("Deux drapeaux à la fois déclenchent les deux widgets")
    func bothFlagsRunBothWidgets() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.map(\.kind) == [.weather, .calculation])
        #expect(report.failures.isEmpty)
    }

    /// Décision produit de Ben : le widget bourse est hors champ. Le type
    /// `SearchWidgetKind` n'expose aucun `case stock`, donc aucun widget ne
    /// peut s'y déclarer ; ce test vérifie le corollaire observable côté
    /// exécuteur — une requête classée « bourse » ne fait rien apparaître.
    @Test("showStockWidget ne déclenche aucun widget (hors champ assumé)")
    func stockFlagTriggersNothing() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(stock: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(SearchWidgetKind.allCases == [.weather, .calculation])
    }

    @Test("Un widget non éligible n'est jamais exécuté, pas seulement ignoré")
    func ineligibleWidgetIsNeverExecuted() async {
        let skippedCounter = ExecutionCounter()
        let runCounter = ExecutionCounter()
        let executor = WidgetExecutor(widgets: [
            StubWidget(
                kind: .weather,
                trigger: { $0.showWeatherWidget },
                behavior: .output(llmContext: "météo", payload: nil),
                counter: runCounter
            ),
            StubWidget(
                kind: .calculation,
                trigger: { $0.showCalculationWidget },
                behavior: .output(llmContext: "calcul", payload: nil),
                counter: skippedCounter
            )
        ])

        _ = await executor.execute(makeInput(makeClassification(weather: true)))

        let executedCount = await runCounter.count
        let skippedCount = await skippedCounter.count
        #expect(executedCount == 1)
        #expect(skippedCount == 0)
    }

    @Test("Exécuteur sans aucun widget injecté : rapport vide, aucun plantage")
    func executorWithoutWidgets() async {
        let executor = WidgetExecutor(widgets: [])

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.failures.isEmpty)
    }

    // MARK: - Tolérance aux pannes

    @Test("Une sortie nil n'est pas un échec : ni sortie, ni trace d'erreur")
    func nilOutputIsNotAFailure() async {
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .nothing)
        ])

        let report = await executor.execute(makeInput(makeClassification(weather: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.failures.isEmpty)
    }

    /// La promesse la plus importante du contrat : même quand TOUT rate,
    /// `execute` rend la main normalement avec un rapport exploitable. C'est
    /// ce qui permet à l'appelant (1.2 / 1.14) de ne jamais entourer l'étape
    /// widgets d'un `try`.
    @Test("Tous les widgets échouent : rapport sans sortie, deux traces, aucune exception")
    func allWidgetsFailingStillReturnsAReport() async {
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .failure),
            StubWidget(kind: .calculation, trigger: { $0.showCalculationWidget }, behavior: .failure)
        ])

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.combinedLLMContext.isEmpty)
        #expect(report.failures == [
            SearchWidgetFailure(kind: .weather, reason: .threw),
            SearchWidgetFailure(kind: .calculation, reason: .threw)
        ])
    }

    @Test("Un widget qui throw est ignoré, tracé, et ne prive pas des autres sorties")
    func throwingWidgetIsIgnoredAndTraced() async {
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .failure),
            StubWidget(
                kind: .calculation,
                trigger: { $0.showCalculationWidget },
                behavior: .output(llmContext: "15 % de 240 = 36", payload: "36")
            )
        ])

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.map(\.kind) == [.calculation])
        #expect(report.failures == [SearchWidgetFailure(kind: .weather, reason: .threw)])
    }

    @Test("Budget de temps dépassé : le widget lent est tracé, le rapide est conservé")
    func slowWidgetTimesOutWithoutBlockingTheFastOne() async {
        let executor = WidgetExecutor(
            widgets: [
                // 10 s : très au-delà du budget, pour que le dépassement soit
                // certain même sur une machine au ralenti.
                StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .sleep(.seconds(10))),
                StubWidget(
                    kind: .calculation,
                    trigger: { $0.showCalculationWidget },
                    behavior: .output(llmContext: "15 % de 240 = 36", payload: "36")
                )
            ],
            totalTimeout: .milliseconds(200)
        )

        let start = ContinuousClock.now
        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))
        let elapsed = ContinuousClock.now - start

        #expect(report.outputs.map(\.kind) == [.calculation])
        #expect(report.failures == [SearchWidgetFailure(kind: .weather, reason: .timedOut)])
        // Preuve que le groupe est bien annulé : sans `cancelAll()`, la sortie
        // du `withTaskGroup` attendrait les 10 s du widget lent.
        #expect(elapsed < Duration.seconds(3))
    }

    /// Vérifie le `pending.removeAll()` de la branche `.deadlineReached` :
    /// le budget est GLOBAL, il doit donc tracer d'un coup TOUS les widgets
    /// encore en vol, pas seulement le premier rencontré.
    @Test("Budget dépassé avec deux widgets lents : les deux sont tracés")
    func deadlineMarksEveryPendingWidget() async {
        let executor = WidgetExecutor(
            widgets: [
                StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .sleep(.seconds(10))),
                StubWidget(kind: .calculation, trigger: { $0.showCalculationWidget }, behavior: .sleep(.seconds(10)))
            ],
            totalTimeout: .milliseconds(200)
        )

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.isEmpty)
        #expect(report.failures == [
            SearchWidgetFailure(kind: .weather, reason: .timedOut),
            SearchWidgetFailure(kind: .calculation, reason: .timedOut)
        ])
    }

    @Test("Tous les widgets répondent avant le délai : on n'attend pas la minuterie")
    func completionDoesNotWaitForTheTimer() async {
        let executor = WidgetExecutor(
            widgets: makeContractualWidgets(),
            totalTimeout: .seconds(30)
        )

        let start = ContinuousClock.now
        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))
        let elapsed = ContinuousClock.now - start

        #expect(report.outputs.count == 2)
        #expect(elapsed < Duration.seconds(3))
    }

    // MARK: - Parallélisme et ordre

    @Test("Les widgets éligibles s'exécutent en parallèle, pas l'un après l'autre")
    func eligibleWidgetsRunInParallel() async {
        let probe = ConcurrencyProbe()
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .probed(probe, hold: .milliseconds(400))),
            StubWidget(kind: .calculation, trigger: { $0.showCalculationWidget }, behavior: .probed(probe, hold: .milliseconds(400)))
        ], totalTimeout: .seconds(30))

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        let maxConcurrent = await probe.maxConcurrent
        #expect(report.outputs.count == 2)
        #expect(maxConcurrent == 2)
    }

    @Test("L'ordre des sorties suit l'ordre d'injection, pas l'ordre d'arrivée")
    func outputOrderFollowsInjectionOrder() async {
        let executor = WidgetExecutor(widgets: [
            // Injecté en premier mais volontairement le plus lent à répondre.
            StubWidget(kind: .calculation, trigger: { $0.showCalculationWidget }, behavior: .sleep(.milliseconds(80))),
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .output(llmContext: "immédiat", payload: nil))
        ], totalTimeout: .seconds(30))

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.map(\.kind) == [.calculation, .weather])
        #expect(report.outputs.first?.llmContext == "tardif")
    }

    // MARK: - Sortie

    @Test("combinedLLMContext concatène les contextes et ignore les vides")
    func combinedLLMContextSkipsEmptyContexts() async {
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .output(llmContext: "   ", payload: "paris")),
            StubWidget(kind: .calculation, trigger: { $0.showCalculationWidget }, behavior: .output(llmContext: "15 % de 240 = 36", payload: "36"))
        ])

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.outputs.count == 2)
        #expect(report.combinedLLMContext == "15 % de 240 = 36")
    }

    /// Le séparateur compte : deux blocs collés se liraient comme une seule
    /// phrase par un petit modèle on-device, qui confondrait alors la météo
    /// et le calcul dans la même affirmation.
    @Test("combinedLLMContext sépare deux contextes par une ligne vide")
    func combinedLLMContextJoinsWithABlankLine() async {
        let executor = WidgetExecutor(widgets: makeContractualWidgets())

        let report = await executor.execute(makeInput(makeClassification(weather: true, calculation: true)))

        #expect(report.combinedLLMContext == "Météo Paris : 18 °C\n\n15 % de 240 = 36")
    }

    @Test("Le payload traverse l'exécuteur en gardant son type réel")
    func payloadKeepsItsConcreteType() async throws {
        let executor = WidgetExecutor(widgets: [
            StubWidget(kind: .weather, trigger: { $0.showWeatherWidget }, behavior: .output(llmContext: "météo", payload: "paris"))
        ])

        let report = await executor.execute(makeInput(makeClassification(weather: true)))

        let payload = try #require(report.outputs.first?.payload as? StubPayload)
        #expect(payload == StubPayload(value: "paris"))
        #expect(report.outputs.first?.id == .weather)
    }
}
