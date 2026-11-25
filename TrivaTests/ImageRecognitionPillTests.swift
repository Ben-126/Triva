//
//  ImageRecognitionPillTests.swift
//  TrivaTests
//
//  W4-V : la capsule d'une image dit qu'elle attend une préparation, la préparation part quand une image est jointe, et
//  retirer une image en cours de lecture libère la file aussitôt (lecture annulée pour de vrai).
//

import Foundation
import Synchronization
import Testing
@testable import Triva

/// Préparateur de pièces jointes factice : `lent…` attend (annulable) ; compte les annulations.
private final class SlowCancellablePreparer: AttachmentPreparing, @unchecked Sendable {
    private let cancelled = Mutex(0)
    var cancelledCount: Int { cancelled.withLock { $0 } }

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        let name = url.lastPathComponent
        if name.hasPrefix("lent") {
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                cancelled.withLock { $0 += 1 }
                throw error
            }
        }
        return IndexedAttachment(
            fileName: name, kind: .plainText, pageCount: nil, characterCount: 10, isTruncated: false, isCopyRestricted: false,
            chunks: [AttachmentChunk(index: 0, text: "Contenu de \(name)", pageRange: nil)]
        )
    }
}

private func pillURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: "/fichiers-factices").appendingPathComponent(fileName)
}

@MainActor
private func waitFor(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func makeController(
    preparer: any AttachmentPreparing = SlowCancellablePreparer(),
    readiness: ImageRecognitionReadiness? = nil
) -> FileAttachmentController {
    let store = AttachmentStore(scorer: LexicalSimilarityScorer(), preparer: preparer)
    return FileAttachmentController(store: store, imageReadiness: readiness)
}

@MainActor
private func makeReadiness(preparer: GatedPreparer = GatedPreparer(), conditions: FakeConditions = FakeConditions()) -> ImageRecognitionReadiness {
    ImageRecognitionReadiness(
        preparer: preparer, ledger: MemoryLedger(), conditions: conditions, key: "k", startDelay: .zero
    )
}

@Suite("Capsule d'image — texte de préparation")
struct ImageRecognitionPresentationTests {
    @Test("Une image en cours de lecture pendant la préparation : la capsule le dit, avec la phrase complète pour VoiceOver")
    func imageWhilePreparing() throws {
        let note = try #require(
            ImageRecognitionPreparationPresentation.note(forFileName: "Image collée 2026-11-25 20.00.00.png", isPreparing: true)
        )
        #expect(note.summary == "Préparation de la lecture d'image")
        #expect(note.detail.contains("Première lecture d'image"))
        #expect(note.detail.contains("continuer à écrire"))
        #expect(note.detail.contains("annuler"))
    }

    @Test("Hors préparation, ou pour un autre fichier : aucune note", arguments: [
        ("capture.png", false), ("rapport.pdf", true), ("notes.txt", true), ("sans-extension", true),
    ])
    func noNote(fileName: String, isPreparing: Bool) {
        #expect(ImageRecognitionPreparationPresentation.note(forFileName: fileName, isPreparing: isPreparing) == nil)
    }

    @Test("Toutes les extensions d'image collées par le presse-papiers sont reconnues", arguments: ["png", "jpg", "heic", "tiff"])
    func pastedFormatsAreImages(fileExtension: String) {
        #expect(ImageRecognitionPreparationPresentation.note(forFileName: "Image collée.\(fileExtension)", isPreparing: true) != nil)
    }
}

@MainActor
@Suite("Capsule d'image — préparation et annulation")
struct ImageRecognitionControllerTests {
    @Test("Sous les tests, le contrôleur n'a pas de préparation (jamais de vrai Vision par défaut)")
    func defaultReadinessIsNilUnderTests() {
        let controller = FileAttachmentController(store: AttachmentStore(scorer: LexicalSimilarityScorer(), preparer: SlowCancellablePreparer()))
        #expect(controller.imageReadiness == nil)
    }

    @Test("Joindre une image lance la préparation, et la capsule le dit pendant qu'elle tourne")
    func attachingImageStartsPreparation() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer)
        let controller = makeController(readiness: readiness)

        controller.enqueue([pillURL("lent-image.png")])

        #expect(readiness.state == .preparing)
        #expect(await waitFor { preparer.callCount == 1 })
        let pending = controller.pendingAttachments.first
        #expect(pending.flatMap {
            ImageRecognitionPreparationPresentation.note(forFileName: $0.fileName, isPreparing: readiness.isPreparing)
        } != nil)
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
    }

    @Test("Image retirée pendant la préparation puis économie d'énergie : plus personne n'attend, la préparation s'arrête")
    func removingTheOnlyImageReleasesThePreparation() async throws {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        let controller = makeController(readiness: readiness)
        controller.enqueue([pillURL("lent-image.png")])
        #expect(await waitFor { preparer.callCount == 1 })
        conditions.set(lowPower: true)
        readiness.conditionsDidChange()
        #expect(readiness.state == .preparing)

        controller.removePendingAttachment(id: try #require(controller.pendingAttachments.first).id)

        #expect(readiness.state == .deferred(.lowPowerMode))
        #expect(await waitFor { preparer.cancelledCount == 1 })
    }

    @Test("Une autre image attend encore : retirer la première ne libère pas la préparation")
    func anotherImageKeepsThePreparation() async throws {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        let controller = makeController(readiness: readiness)
        controller.enqueue(["lent-1.png", "lent-2.png"].map(pillURL))
        #expect(await waitFor { preparer.callCount == 1 })
        conditions.set(lowPower: true)

        controller.removePendingAttachment(id: try #require(controller.pendingAttachments.first).id)
        readiness.conditionsDidChange()

        #expect(readiness.state == .preparing)
    }

    @Test("Joindre un texte ne lance rien")
    func attachingTextDoesNotPrepare() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer)
        let controller = makeController(readiness: readiness)

        controller.enqueue([pillURL("notes.txt")])

        #expect(await waitFor { controller.pendingAttachments.isEmpty })
        #expect(readiness.state == .idle)
        #expect(preparer.callCount == 0)
    }

    @Test("Image retirée pendant sa lecture : la lecture est annulée et la suite de la file passe aussitôt")
    func removingReadingFileCancelsItsRead() async throws {
        let preparer = SlowCancellablePreparer()
        let controller = makeController(preparer: preparer)
        controller.enqueue(["lent.txt", "b.txt"].map(pillURL))
        let slow = try #require(controller.pendingAttachments.first)
        try await Task.sleep(for: .milliseconds(100))  // la lecture de « lent » a commencé

        controller.removePendingAttachment(id: slow.id)

        #expect(await waitFor { controller.pendingAttachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["b.txt"])
        #expect(controller.notices.isEmpty)
        #expect(preparer.cancelledCount == 1)
    }

    @Test("Nouvelle conversation pendant une lecture lente : la lecture est annulée")
    func removeAllCancelsCurrentRead() async throws {
        let preparer = SlowCancellablePreparer()
        let controller = makeController(preparer: preparer)
        controller.enqueue([pillURL("lent.txt")])
        try await Task.sleep(for: .milliseconds(100))

        controller.removeAll()

        #expect(await waitFor { preparer.cancelledCount == 1 })
        #expect(controller.isEmpty)
        controller.enqueue([pillURL("nouveau.txt")])
        #expect(await waitFor { controller.attachments.map(\.fileName) == ["nouveau.txt"] })
    }
}
