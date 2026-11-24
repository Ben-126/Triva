//
//  EraseAllBrowserAndVaultTests.swift
//  TrivaTests
//
//  Mission K1 (2026-11-24, décisions de Ben) : « Tout effacer » dit à l'utilisateur quand Safari n'a pas répondu
//  (effacement incomplet, réessayer) au lieu de continuer en silence, et vide aussi les copies de fichiers des
//  fenêtres ouvertes SANS que leur aperçu ouvert ne reste sur un fichier disparu.
//

import Foundation
import Testing
@testable import Triva

/// Relevé des signaux reçus (l'observateur de notification est `@Sendable` : un simple `var` ne peut pas le capturer).
private final class SignalLog: @unchecked Sendable {
    var existedAtSignal: [Bool] = []
    var count = 0
}

@MainActor
private final class CountingDeleter: AllDeleting {
    private(set) var callCount = 0
    private let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    struct Failure: Error {}

    func deleteAll() throws {
        callCount += 1
        if fails { throw Failure() }
    }
}

@MainActor
private func makeEraser(
    history: CountingDeleter = CountingDeleter(),
    favorites: CountingDeleter = CountingDeleter(),
    vaultRoot: URL? = nil,
    center: NotificationCenter = NotificationCenter(),
    dismissDelay: Duration = .zero,
    clearBrowser: @escaping @MainActor () async -> EmbeddedBrowserClearOutcome
) -> LocalDataEraser {
    LocalDataEraser(
        chatHistory: history,
        favorites: favorites,
        discoverCache: DiscoverNoCache(),
        urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
        storage: nil,
        clearBrowserData: clearBrowser,
        attachmentVaultRoot: vaultRoot,
        previewDismissDelay: dismissDelay,
        vaultPurgeCenter: center
    )
}

/// Ce que `eraseAll` a levé (`nil` : effacement complet).
@MainActor
private func thrownError(by eraser: LocalDataEraser) async -> LocalDataEraseError? {
    do {
        try await eraser.eraseAll()
        return nil
    } catch {
        return error
    }
}

/// Dossier racine de coffre jetable avec une copie dedans.
@MainActor
private func makeVault() throws -> (root: URL, copy: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EraseVault-\(UUID().uuidString)", isDirectory: true)
    let copy = root.appendingPathComponent("session/id/notes.txt")
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("document privé".utf8).write(to: copy)
    return (root, copy)
}

@MainActor
@Suite("Tout effacer : Safari qui ne répond pas")
struct EraseAllBrowserTimeoutTests {
    @Test("Safari n'a pas répondu : .incomplete([navigateur]), et tout le reste a quand même été effacé")
    func timeoutIsReported() async throws {
        let history = CountingDeleter()
        let favorites = CountingDeleter()
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }

        let thrown = await thrownError(by: makeEraser(history: history, favorites: favorites, vaultRoot: vault.root) { .timedOut })

        #expect(thrown == .incomplete(failedSteps: [.browser]))
        #expect(history.callCount == 1)
        #expect(favorites.callCount == 1)
        #expect(!FileManager.default.fileExists(atPath: vault.copy.path))
    }

    @Test("Safari a répondu : aucune erreur")
    func completedBrowserClearIsNotAnError() async {
        let thrown = await thrownError(by: makeEraser { .completed })
        #expect(thrown == nil)
    }

    @Test("Échec de l'historique ET Safari muet : les deux sont signalés, dans l'ordre")
    func databaseFailureAndTimeoutAreBothReported() async {
        let thrown = await thrownError(by: makeEraser(history: CountingDeleter(fails: true)) { .timedOut })
        #expect(thrown == .incomplete(failedSteps: [.history, .browser]))
    }

    @Test("Le vrai vidage, face à un Safari qui ne répond jamais, rend la main au délai et le dit")
    func neverRespondingSafariEndsAsIncomplete() async {
        let clearer = EmbeddedBrowserDataClearer(timeout: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(3600))
        }
        let started = ContinuousClock.now

        let thrown = await thrownError(by: makeEraser { await clearer.clear() })

        #expect(thrown == .incomplete(failedSteps: [.browser]))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Le message de l'écran dit que le navigateur intégré n'a pas été vidé, et de réessayer")
    func messageMentionsTheBrowser() {
        let alone = LocalDataEraseSection.incompleteMessage(failedSteps: [.browser])
        let withHistory = LocalDataEraseSection.incompleteMessage(failedSteps: [.history, .browser])
        let withEverything = LocalDataEraseSection.incompleteMessage(failedSteps: [.favorites, .history, .browser])

        #expect(alone.contains("navigateur intégré"))
        #expect(alone.contains("Réessaie"))
        #expect(withHistory.contains("conversations n'ont pas pu être effacées"))
        #expect(withHistory.contains("navigateur intégré"))
        #expect(withEverything.contains("conversations et tes favoris n'ont pas pu être effacés"))
        #expect(withEverything.contains("navigateur intégré"))
        for message in [alone, withHistory, withEverything] {
            #expect(!message.contains("Tout a été effacé"))
        }
    }
}

@MainActor
@Suite("Tout effacer : copies de fichiers et aperçu ouvert")
struct EraseAllVaultSignalTests {
    @Test("Les fenêtres sont prévenues AVANT la suppression des copies (leur aperçu a le temps de se fermer)")
    func windowsAreToldBeforeTheCopiesDisappear() async throws {
        let center = NotificationCenter()
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let log = SignalLog()
        let copyPath = vault.copy.path
        let token = center.addObserver(forName: AttachmentVaultPurgeSignal.notificationName, object: nil, queue: nil) { _ in
            log.existedAtSignal.append(FileManager.default.fileExists(atPath: copyPath))
        }
        defer { center.removeObserver(token) }

        try await makeEraser(vaultRoot: vault.root, center: center) { .completed }.eraseAll()

        #expect(log.existedAtSignal == [true])
        #expect(!FileManager.default.fileExists(atPath: vault.root.path))
    }

    @Test("Le délai laissé aux aperçus est respecté avant la suppression")
    func previewDismissDelayIsHonoured() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let started = ContinuousClock.now

        try await makeEraser(vaultRoot: vault.root, dismissDelay: .milliseconds(300)) { .completed }.eraseAll()

        #expect(ContinuousClock.now - started >= .milliseconds(250))
    }

    @Test("Sans dossier de coffre (tests, aperçus), personne n'est prévenu et rien n'est attendu")
    func noVaultNoSignal() async throws {
        let center = NotificationCenter()
        let log = SignalLog()
        let token = center.addObserver(forName: AttachmentVaultPurgeSignal.notificationName, object: nil, queue: nil) { _ in log.count += 1 }
        defer { center.removeObserver(token) }

        try await makeEraser(center: center, dismissDelay: .seconds(60)) { .completed }.eraseAll()

        #expect(log.count == 0)
    }
}

@MainActor
@Suite("Pièces jointes : « Tout effacer » vide les copies des fenêtres ouvertes")
struct AttachmentControllerPurgeTests {
    private func sandbox() throws -> (origin: URL, vaultRoot: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PurgeSignal-\(UUID().uuidString)", isDirectory: true)
        let origin = root.appendingPathComponent("origine", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        return (origin, root.appendingPathComponent("coffre", isDirectory: true), { try? FileManager.default.removeItem(at: root) })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("Le signal fait oublier les copies : plus de Coup d'œil, mais le texte déjà lu reste joint")
    func controllerForgetsItsCopies() async throws {
        let box = try sandbox()
        defer { box.cleanup() }
        let center = NotificationCenter()
        let source = box.origin.appendingPathComponent("notes.txt")
        try Data("Le ciel est bleu.".utf8).write(to: source)
        let controller = FileAttachmentController(
            store: AttachmentStore(), vault: AttachmentFileVault(rootDirectory: box.vaultRoot), purgeSignalCenter: center
        )
        controller.enqueue([source])
        #expect(await waitUntil { controller.attachments.count == 1 })
        let attachment = try #require(controller.attachments.first)
        #expect(controller.previewURL(for: attachment.id) != nil)

        AttachmentVaultPurgeSignal.post(root: box.vaultRoot, on: center)

        #expect(controller.storedFileURLs.isEmpty)
        #expect(controller.previewURL(for: attachment.id) == nil)
        #expect(controller.attachments.count == 1)
    }

    @Test("Le signal d'un AUTRE coffre ne touche pas les copies de cette fenêtre")
    func otherVaultSignalIsIgnored() async throws {
        let box = try sandbox()
        defer { box.cleanup() }
        let center = NotificationCenter()
        let source = box.origin.appendingPathComponent("notes.txt")
        try Data("Le ciel est bleu.".utf8).write(to: source)
        let controller = FileAttachmentController(
            store: AttachmentStore(), vault: AttachmentFileVault(rootDirectory: box.vaultRoot), purgeSignalCenter: center
        )
        controller.enqueue([source])
        #expect(await waitUntil { controller.attachments.count == 1 })
        let attachment = try #require(controller.attachments.first)

        AttachmentVaultPurgeSignal.post(root: box.origin, on: center)

        #expect(controller.previewURL(for: attachment.id) != nil)
    }

    @Test("Un dépôt encore en file (sa copie va disparaître) est retiré, un fichier choisi dans le sélecteur reste")
    func queuedDepositsAreDropped() async throws {
        let box = try sandbox()
        defer { box.cleanup() }
        let center = NotificationCenter()
        let chosen = box.origin.appendingPathComponent("choisi.txt")
        try Data("choisi".utf8).write(to: chosen)
        let received = box.origin.appendingPathComponent("depose.txt")
        try Data("déposé".utf8).write(to: received)
        let deposit = try AttachmentFileVault.stageDeposit(of: received, rootDirectory: box.vaultRoot)
        let controller = FileAttachmentController(
            store: AttachmentStore(), vault: AttachmentFileVault(rootDirectory: box.vaultRoot), purgeSignalCenter: center
        )
        controller.enqueue([deposit], areDeposits: true)
        controller.enqueue([chosen])
        #expect(controller.pendingAttachments.count == 2)

        AttachmentVaultPurgeSignal.post(root: box.vaultRoot, on: center)

        #expect(controller.pendingAttachments.map(\.fileName) == ["choisi.txt"])
    }

    @Test("Une fenêtre fermée n'écoute plus : signaler après sa disparition ne plante pas")
    func closedWindowDoesNotListenAnymore() async throws {
        let center = NotificationCenter()
        var controller: FileAttachmentController? = FileAttachmentController(
            store: AttachmentStore(), purgeSignalCenter: center
        )
        controller = nil

        AttachmentVaultPurgeSignal.post(root: FileManager.default.temporaryDirectory, on: center)

        #expect(controller == nil)
    }
}
