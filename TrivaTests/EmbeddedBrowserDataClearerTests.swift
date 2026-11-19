//
//  EmbeddedBrowserDataClearerTests.swift
//  TrivaTests
//
//  Mission T1 (2026-11-19) : les vidages simultanés du navigateur intégré s'invalidaient entre eux
//  et figeaient les tests sur simulateur. Ici : un seul vidage à la fois, et un délai maximal.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("EmbeddedBrowserDataClearer")
struct EmbeddedBrowserDataClearerTests {
    /// Compteur d'appels à l'opération réelle (main actor, donc sans verrou).
    private final class Calls {
        var started = 0
        var finished = 0
    }

    @Test("Un vidage seul : l'opération tourne une fois et le résultat est « terminé »")
    func singleClearRunsOnce() async {
        let calls = Calls()
        let clearer = EmbeddedBrowserDataClearer(timeout: .seconds(30)) {
            calls.started += 1
            calls.finished += 1
        }
        let outcome = await clearer.clear()
        #expect(outcome == .completed)
        #expect(calls.started == 1)
    }

    @Test("Des appels simultanés partagent UN seul vidage (sinon Safari les invalide entre eux)")
    func concurrentCallsShareOneClear() async {
        let calls = Calls()
        let clearer = EmbeddedBrowserDataClearer(timeout: .seconds(30)) {
            calls.started += 1
            try? await Task.sleep(for: .milliseconds(150))
            calls.finished += 1
        }
        async let first = clearer.clear()
        async let second = clearer.clear()
        async let third = clearer.clear()
        let outcomes = await [first, second, third]

        #expect(outcomes == [.completed, .completed, .completed])
        #expect(calls.started == 1)
        #expect(calls.finished == 1)
    }

    @Test("Après un vidage terminé, un nouvel appel relance une vraie opération")
    func sequentialCallsEachRun() async {
        let calls = Calls()
        let clearer = EmbeddedBrowserDataClearer(timeout: .seconds(30)) { calls.started += 1 }
        await clearer.clear()
        await clearer.clear()
        #expect(calls.started == 2)
    }

    @Test("Une opération qui ne répond jamais n'attend pas plus que le délai")
    func neverRespondingOperationTimesOut() async {
        let clearer = EmbeddedBrowserDataClearer(timeout: .milliseconds(100)) {
            // Comme `clearWebsiteData()` sur simulateur : la continuation n'est jamais reprise, et ne
            // réagit pas à l'annulation (donc pas de `Task.sleep`, qui, lui, la respecterait).
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        let started = ContinuousClock.now
        let outcome = await clearer.clear()
        let elapsed = ContinuousClock.now - started

        #expect(outcome == .timedOut)
        #expect(elapsed < .seconds(10))
    }

    @Test("Après un délai dépassé, le vidage suivant repart sur une nouvelle opération")
    func clearAfterTimeoutStartsAgain() async {
        let calls = Calls()
        let clearer = EmbeddedBrowserDataClearer(timeout: .milliseconds(100)) {
            calls.started += 1
            if calls.started == 1 {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        let first = await clearer.clear()
        let second = await clearer.clear()

        #expect(first == .timedOut)
        #expect(second == .completed)
        #expect(calls.started == 2)
    }
}
