//
//  FileAttachmentVaultIntegrationTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M5) : le contrôleur de pièces jointes et le coffre ensemble (Coup d'œil, dépôt), puis l'effet
//  d'un dépôt sur la fenêtre. Vrais fichiers, vraie lecture, dossier temporaire de test.
//

import Foundation
import Testing
@testable import Triva

private func waitFor(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

private struct VaultTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Dossier de test : origine des fichiers et racine du coffre. Supprimé en fin de test.
private func withSandbox<T>(_ body: (_ origin: URL, _ vaultRoot: URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("VaultIntegration-\(UUID().uuidString)", isDirectory: true)
    let origin = root.appendingPathComponent("origine", isDirectory: true)
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(origin, root.appendingPathComponent("coffre", isDirectory: true))
}

private func write(_ name: String, _ text: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

@MainActor
@Suite("Pièces jointes — contrôleur et coffre")
struct FileAttachmentVaultControllerTests {
    private func makeController(vaultRoot: URL) -> FileAttachmentController {
        FileAttachmentController(store: AttachmentStore(), vault: AttachmentFileVault(rootDirectory: vaultRoot), purgeSignalCenter: NotificationCenter())
    }

    @Test("Un fichier joint est lu sur sa copie : Coup d'œil disponible, original intact")
    func attachedFileHasPreview() async throws {
        try await withSandbox { origin, vaultRoot in
            let source = try write("notes.txt", "Le ciel est bleu.", in: origin)
            let controller = makeController(vaultRoot: vaultRoot)
            controller.enqueue([source])
            #expect(await waitFor { controller.attachments.count == 1 })
            let attachment = try #require(controller.attachments.first)
            let preview = try #require(controller.previewURL(for: attachment.id))
            #expect(preview != source)
            #expect(preview.lastPathComponent == "notes.txt")
            #expect(try String(contentsOf: preview, encoding: .utf8) == "Le ciel est bleu.")
            #expect(exists(source))
        }
    }

    @Test("Retirer la pièce jointe efface sa copie")
    func removingDeletesCopy() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            controller.enqueue([try write("a.txt", "un", in: origin), try write("b.txt", "deux", in: origin)])
            #expect(await waitFor { controller.attachments.count == 2 })
            let first = try #require(controller.attachments.first)
            let second = try #require(controller.attachments.last)
            let firstCopy = try #require(controller.previewURL(for: first.id))
            let secondCopy = try #require(controller.previewURL(for: second.id))
            controller.removeAttachment(id: first.id)
            #expect(!exists(firstCopy))
            #expect(controller.previewURL(for: first.id) == nil)
            #expect(exists(secondCopy))
        }
    }

    @Test("Nouvelle conversation : toutes les copies disparaissent")
    func removeAllDeletesCopies() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            controller.enqueue([try write("a.txt", "un", in: origin)])
            #expect(await waitFor { controller.attachments.count == 1 })
            let attachment = try #require(controller.attachments.first)
            let copy = try #require(controller.previewURL(for: attachment.id))
            controller.removeAll()
            #expect(!exists(copy))
            #expect(controller.storedFileURLs.isEmpty)
            #expect(controller.attachments.isEmpty)
        }
    }

    @Test("Fenêtre fermée (contrôleur libéré) : le dossier de la conversation est effacé")
    func deinitDeletesSession() async throws {
        try await withSandbox { origin, vaultRoot in
            let vault = AttachmentFileVault(rootDirectory: vaultRoot)
            var controller: FileAttachmentController? = FileAttachmentController(store: AttachmentStore(), vault: vault, purgeSignalCenter: NotificationCenter())
            controller?.enqueue([try write("a.txt", "un", in: origin)])
            #expect(await waitFor { controller?.attachments.count == 1 })
            #expect(exists(vault.sessionDirectory))
            controller = nil
            #expect(!exists(vault.sessionDirectory))
        }
    }

    @Test("Un fichier refusé (type inconnu) ne laisse aucune copie")
    func refusedFileLeavesNothing() async throws {
        try await withSandbox { origin, vaultRoot in
            let vault = AttachmentFileVault(rootDirectory: vaultRoot)
            let controller = FileAttachmentController(store: AttachmentStore(), vault: vault, purgeSignalCenter: NotificationCenter())
            controller.enqueue([try write("archive.zip", "zip", in: origin)])
            #expect(await waitFor { controller.pendingAttachments.isEmpty && !controller.notices.isEmpty })
            #expect(controller.attachments.isEmpty)
            #expect(!exists(vault.sessionDirectory))
        }
    }

    @Test("Un dépôt est adopté par la conversation ; un doublon est effacé des dépôts")
    func depositIsAdoptedAndDuplicateDiscarded() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            let first = try AttachmentFileVault.stageDeposit(of: try write("a.txt", "un", in: origin), rootDirectory: vaultRoot)
            controller.enqueue([first], areDeposits: true)
            #expect(await waitFor { controller.attachments.count == 1 })
            #expect(!exists(first))
            let attachment = try #require(controller.attachments.first)
            #expect(try String(contentsOf: try #require(controller.previewURL(for: attachment.id)), encoding: .utf8) == "un")

            let duplicate = try AttachmentFileVault.stageDeposit(of: try write("a.txt", "un", in: origin), rootDirectory: vaultRoot)
            controller.enqueue([duplicate], areDeposits: true)
            #expect(!exists(duplicate))
            #expect(controller.attachments.count == 1)
            #expect(controller.notices.contains { $0.message == FileAttachmentPresentation.alreadyAttachedMessage })
        }
    }

    @Test("Au-delà de la limite, les dépôts en trop sont effacés")
    func overflowDepositsAreDiscarded() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = FileAttachmentController(
                store: AttachmentStore(), maxAttachmentCount: 1, vault: AttachmentFileVault(rootDirectory: vaultRoot),
                purgeSignalCenter: NotificationCenter()
            )
            let kept = try AttachmentFileVault.stageDeposit(of: try write("a.txt", "un", in: origin), rootDirectory: vaultRoot)
            let extra = try AttachmentFileVault.stageDeposit(of: try write("b.txt", "deux", in: origin), rootDirectory: vaultRoot)
            controller.enqueue([kept, extra], areDeposits: true)
            #expect(!exists(extra))
            #expect(await waitFor { controller.attachments.count == 1 })
        }
    }

    // MARK: Dépôts en attente jamais lus (confidentialité : rien ne doit rester dans tmp)

    /// Trois dépôts en file : la lecture n'a pas encore commencé (le test ne se suspend pas entre l'ajout et l'action).
    private func stageThree(in origin: URL, vaultRoot: URL) throws -> [URL] {
        try ["a.txt", "b.txt", "c.txt"].map {
            try AttachmentFileVault.stageDeposit(of: try write($0, "contenu de \($0)", in: origin), rootDirectory: vaultRoot)
        }
    }

    @Test("Nouvelle conversation : les dépôts en attente sont effacés de tmp")
    func removeAllDiscardsQueuedDeposits() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            let deposits = try stageThree(in: origin, vaultRoot: vaultRoot)
            controller.enqueue(deposits, areDeposits: true)
            controller.removeAll()
            #expect(deposits.allSatisfy { !exists($0) && !exists($0.deletingLastPathComponent()) })
            #expect(controller.pendingAttachments.isEmpty)
        }
    }

    @Test("Capsule en attente retirée : son dépôt est effacé, les autres restent")
    func removingPendingDiscardsOnlyItsDeposit() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            let deposits = try stageThree(in: origin, vaultRoot: vaultRoot)
            controller.enqueue(deposits, areDeposits: true)
            let second = try #require(controller.pendingAttachments.dropFirst().first)
            controller.removePendingAttachment(id: second.id)
            #expect(!exists(deposits[1]))
            #expect(exists(deposits[0]))
            #expect(exists(deposits[2]))
            controller.removeAll()
        }
    }

    @Test("Budget de caractères épuisé : les dépôts abandonnés sont effacés")
    func exhaustedBudgetDiscardsAbandonedDeposits() async throws {
        try await withSandbox { origin, vaultRoot in
            let store = AttachmentStore(scorer: LexicalSimilarityScorer(), totalCharacterBudget: 5)
            let controller = FileAttachmentController(store: store, vault: AttachmentFileVault(rootDirectory: vaultRoot), purgeSignalCenter: NotificationCenter())
            let deposits = try stageThree(in: origin, vaultRoot: vaultRoot)
            controller.enqueue(deposits, areDeposits: true)
            #expect(await waitFor { controller.pendingAttachments.isEmpty })
            #expect(controller.attachments.count == 1)
            #expect(!exists(deposits[1]))
            #expect(!exists(deposits[2]))
        }
    }

    @Test("Fenêtre fermée (le contrôleur disparaît) : les dépôts en attente sont effacés")
    func deinitDiscardsQueuedDeposits() async throws {
        try await withSandbox { origin, vaultRoot in
            let deposits = try stageThree(in: origin, vaultRoot: vaultRoot)
            var controller: FileAttachmentController? = makeController(vaultRoot: vaultRoot)
            controller?.enqueue(deposits, areDeposits: true)
            #expect(deposits.allSatisfy(exists))
            controller = nil
            #expect(deposits.allSatisfy { !exists($0) })
        }
    }

    @Test("Copie disparue du disque : plus de Coup d'œil, sans erreur")
    func missingCopyHidesPreview() async throws {
        try await withSandbox { origin, vaultRoot in
            let controller = makeController(vaultRoot: vaultRoot)
            controller.enqueue([try write("a.txt", "un", in: origin)])
            #expect(await waitFor { controller.attachments.count == 1 })
            let attachment = try #require(controller.attachments.first)
            let copy = try #require(controller.previewURL(for: attachment.id))
            try FileManager.default.removeItem(at: copy)
            #expect(controller.previewURL(for: attachment.id) == nil)
        }
    }
}

@MainActor
@Suite("Dépôt — effet sur la fenêtre")
struct DropOnWindowTests {
    private func makeCoordinator() throws -> TrivaRootCoordinator {
        let userDefaults = try #require(TestDefaults.suite(named: "test.drop.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
            keyStore: VaultTestKeyStore()
        )
        return TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: WindowConversationRegistry())
    }

    @Test("Un texte déposé arrive dans le brouillon, sans rien envoyer, et ramène à la Recherche")
    func textGoesToDraft() throws {
        let coordinator = try makeCoordinator()
        coordinator.selection = .library
        coordinator.session.draft.text = "Que penses-tu de"
        coordinator.receiveDrop([.text("la tour Eiffel ?")])
        #expect(coordinator.session.draft.text == "Que penses-tu de la tour Eiffel ?")
        #expect(coordinator.selection == .search)
        #expect(coordinator.session.chatViewModel?.messages.isEmpty == true)
    }

    @Test("Un fichier déposé est joint à la conversation, avec sa copie pour le Coup d'œil")
    func fileIsAttached() async throws {
        let coordinator = try makeCoordinator()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DropWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deposit = try AttachmentFileVault.stageDeposit(of: try write("dossier.md", "# Titre\nTexte.", in: folder))

        coordinator.receiveDrop([.attachment(deposit)])
        let controller = try #require(coordinator.session.chatViewModel?.attachmentController)
        #expect(await waitFor { controller.attachments.count == 1 })
        let attachment = try #require(controller.attachments.first)
        #expect(controller.previewURL(for: attachment.id) != nil)
        #expect(!exists(deposit))
        controller.removeAll()
    }

    @Test("Un refus est expliqué sous les capsules, sans nom de fichier")
    func refusalsAreExplained() throws {
        let coordinator = try makeCoordinator()
        coordinator.receiveDrop([.refused(.tooLarge)])
        let controller = try #require(coordinator.session.chatViewModel?.attachmentController)
        #expect(controller.notices.last?.message == DropRefusal.tooLarge.message)
        #expect(controller.notices.last?.fileNames.isEmpty == true)
    }

    @Test("Un dépôt vide ne fait rien")
    func emptyDropDoesNothing() throws {
        let coordinator = try makeCoordinator()
        coordinator.selection = .discover
        #expect(coordinator.receiveDrop([]) == nil)
        #expect(coordinator.selection == .discover)
    }
}
