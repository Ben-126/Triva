//
//  GatedLanguageModelTests.swift
//  TrivaTests
//
//  Mission M (25/11) : l'enveloppe du modèle MLX. Le modèle est un double ; aucun calcul n'est évalué. Jamais sur
//  simulateur : y créer un tableau MLX fait planter l'app (Metal).
//

#if !targetEnvironment(simulator)
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import Triva

nonisolated private final class FakeModel: Module, LanguageModel {
    let calls = GateCounter()
    let prepares = GateCounter()
    nonisolated(unsafe) var receivedPrefill: PrefillParameters?

    var reasoningConfig: ReasoningConfig? { .thinkTagsWithEnableThinking }
    var toolCallFormat: ToolCallFormat? { .json }

    func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
        prepares.increment()
        receivedPrefill = prefill
        return .tokens(input.text)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        calls.increment()
        return inputs
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] { [] }
}

@Suite("Mission M — enveloppe du modèle MLX")
struct GatedLanguageModelTests {
    private let drains = GateCounter()

    private func wrap(_ model: FakeModel, _ gate: LocalGPUGate) -> GatedLanguageModel {
        GatedLanguageModel(model, gate: gate, drain: { [drains] in drains.increment() })
    }

    @Test("Morceaux de question plus courts, jamais plus longs que demandé", arguments: [
        (nil, 256), (1024, 256), (512, 256), (64, 64),
    ] as [(Int?, Int)])
    func prefillStep(requested: Int?, expected: Int) {
        let gated = GatedLanguageModel.gated(
            PrefillParameters(stepSize: requested), gate: LocalGPUGate(isEnforced: true, initialPhase: .active), drain: {}
        )
        #expect(gated.stepSize == expected)
    }

    @Test("Après chaque morceau : l'avancement d'origine est transmis, puis la barrière est passée")
    func prefillProgress() async {
        let gate = LocalGPUGate(isEnforced: true, initialPhase: .inactive)
        let reported = GateCounter()
        let gated = GatedLanguageModel.gated(
            PrefillParameters(progress: { _, _ in reported.increment() }), gate: gate, drain: { [drains] in drains.increment() }
        )
        let passed = GateCounter()
        Thread.detachNewThread {
            gated.progress?(256, 1000)
            passed.increment()
        }
        #expect(await gateWait { gate.counts.parked == 1 })
        #expect(reported.value == 1)
        #expect(drains.value == 1)
        #expect(passed.value == 0)
        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
    }

    @Test("Conventions de dialogue transmises : sans elles, Qwen3 perdrait sa gestion du raisonnement")
    func conventionsAreForwarded() {
        let wrapped = wrap(FakeModel(), LocalGPUGate(isEnforced: true, initialPhase: .active))
        #expect(wrapped.reasoningConfig != nil)
        #expect(wrapped.toolCallFormat == .json)
        #expect(!wrapped.training)
    }

    @Test("Chaque étape atteint le modèle, une seule fois, et lit la question par morceaux courts")
    func stepsReachTheModel() throws {
        let model = FakeModel()
        let wrapped = wrap(model, LocalGPUGate(isEnforced: true, initialPhase: .active))
        let tokens = MLXArray([1, 2, 3])
        _ = wrapped(LMInput.Text(tokens: tokens), cache: nil, state: nil)
        _ = wrapped(tokens, cache: nil)
        #expect(model.calls.value == 2)
        _ = try wrapped.prepare(LMInput(text: .init(tokens: tokens)), cache: [], state: nil, prefill: .init())
        #expect(model.prepares.value == 1)
        #expect(model.receivedPrefill?.stepSize == GatedLanguageModel.prefillStepLimit)
        #expect(drains.value == 0)
    }

    @Test("App inactive : l'étape n'atteint le modèle qu'au retour")
    func stepWaits() async {
        let model = FakeModel()
        let gate = LocalGPUGate(isEnforced: true, initialPhase: .inactive)
        let wrapped = UncheckedBox(wrap(model, gate))
        Thread.detachNewThread { _ = wrapped.value(MLXArray([1]), cache: nil) }
        #expect(await gateWait { gate.counts.parked == 1 })
        #expect(model.calls.value == 0)
        #expect(drains.value == 1)
        gate.setPhase(.active)
        let calls = model.calls
        #expect(await gateWait { calls.value == 1 })
    }
}

nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

nonisolated private struct FakeDownloader: Downloader {
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL { URL(filePath: "/modele") }
}

@Suite("Mission M — chargement du modèle après son téléchargement")
struct GatedDownloaderTests {
    @Test("Téléchargement fini en arrière-plan : le chargement attend le premier plan, sans échouer, puis est compté")
    func loadWaitsForForeground() async throws {
        let gate = LocalGPUGate(isEnforced: true, initialPhase: .background)
        let load = GatedLoad()
        let downloader = GatedDownloader(base: FakeDownloader(), gate: gate, load: load)
        let finished = GateCounter()
        let task = Task.detached {
            let url = try await downloader.download(id: "m", revision: nil, matching: [], useLatest: false) { _ in }
            finished.increment()
            return url
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.value == 0)
        gate.setPhase(.active)
        #expect(try await task.value == URL(filePath: "/modele"))
        #expect(gate.counts.running == 1)
        // Second téléchargement du même chargement (tokenizer) : toujours UN travail.
        _ = try await downloader.download(id: "t", revision: nil, matching: [], useLatest: false) { _ in }
        #expect(gate.counts.running == 1)
        load.finish()
        load.finish()
        #expect(gate.counts.running == 0)
    }
}
#endif
