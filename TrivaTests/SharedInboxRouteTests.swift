//
//  SharedInboxRouteTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : du partage à la barre de saisie. Le routeur ne rend un fichier que s'il est DANS les
//  dépôts de l'app ; la fenêtre le joint par le point d'entrée du glisser-déposer ; l'app reprend la boîte à
//  chaque passage au premier plan, sans jamais envoyer.
//

import Foundation
import Testing
@testable import Triva

private struct ShareTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private struct RouteFixture {
    let root: URL
    var depositRoot: URL { root.appendingPathComponent("vault", isDirectory: true) }

    init() throws { root = try TestFiles.makeFolder("shareroute") }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Un vrai dépôt, comme le fait `AttachmentFileVault.stageDeposit`.
    func deposit(_ name: String = "Cours.pdf", bytes: Data = SampleBytes.pdf()) throws -> URL {
        let source = try TestFiles.write(bytes, named: name, in: root)
        return try AttachmentFileVault.stageDeposit(of: source, rootDirectory: depositRoot)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
@Suite("Partage — routeur et fichiers")
struct SharedAttachmentRouteTests {
    @Test("Un fichier des dépôts attend dans la file et n'est rendu qu'une fois")
    func depositRouteIsQueuedOnce() throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let center = SystemRouteCenter(windowLauncher: nil, depositRoot: fixture.depositRoot)
        let deposit = try fixture.deposit()
        center.submit(.attachment(deposit))
        #expect(center.drain() == [.attachment(deposit)])
        #expect(center.drain().isEmpty)
        #expect(fixture.exists(deposit), "le routeur ne touche pas au fichier tant qu'une fenêtre ne l'a pas pris")
    }

    @Test("Hors des dépôts, la route est jetée : fichier de l'utilisateur, dossier des dépôts, `..`, adresse web")
    func outsideDepositsIsRefused() throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let center = SystemRouteCenter(windowLauncher: nil, depositRoot: fixture.depositRoot)
        let own = try TestFiles.write(SampleBytes.pdf(), named: "Mes notes.pdf", in: fixture.root)
        let direct = fixture.depositRoot.appendingPathComponent("_deposits/direct.pdf")
        let traversal = fixture.depositRoot.appendingPathComponent("_deposits/\(UUID().uuidString)/../../../Mes notes.pdf")
        let web = try #require(URL(string: "https://exemple.fr/x.pdf"))
        for refused in [own, direct, traversal, web, URL(fileURLWithPath: "/etc/hosts")] {
            center.submit(.attachment(refused))
        }
        #expect(center.drain().isEmpty)
        #expect(fixture.exists(own), "un fichier hors dépôts n'est jamais supprimé")
    }

    @Test("File pleine : un fichier évincé est effacé des dépôts, rien ne traîne")
    func evictedAttachmentIsDiscarded() throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let center = SystemRouteCenter(windowLauncher: nil, depositRoot: fixture.depositRoot)
        let first = try fixture.deposit("premier.pdf")
        center.submit(.attachment(first))
        for _ in 0..<SystemRouteCenter.maxPending { center.submit(.conversation(UUID())) }
        #expect(!fixture.exists(first))
        #expect(center.drain().count == SystemRouteCenter.maxPending)
    }

    @Test("Mac : l'extension de partage n'existe pas, un fichier reçu quand même est effacé, jamais ouvert")
    func macDiscardsTheDeposit() throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher, depositRoot: fixture.depositRoot)
        let deposit = try fixture.deposit()
        center.submit(.attachment(deposit))
        #expect(launcher.drain().isEmpty)
        #expect(!fixture.exists(deposit))
    }

    @Test("Une route fichier ne s'écrit pas en URL triva://")
    func noURLForAttachment() throws {
        let deposit = URL(fileURLWithPath: "/tmp/x.pdf")
        #expect(TrivaURLRoute.url(for: .attachment(deposit)) == nil)
    }
}

@MainActor
@Suite("Partage — la fenêtre joint le fichier")
struct SharedAttachmentWindowTests {
    private func makeCoordinator() throws -> TrivaRootCoordinator {
        let defaults = try #require(TestDefaults.suite(named: "test.shareWindow.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: ShareTestKeyStore()
        )
        return TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: WindowConversationRegistry())
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("Un PDF partagé est joint à la conversation de la fenêtre, la Recherche s'affiche, rien n'est envoyé")
    func pdfIsAttachedNotSent() async throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let coordinator = try makeCoordinator()
        coordinator.selection = .library
        let deposit = try AttachmentFileVault.stageDeposit(
            of: try TestFiles.write(Data("# Notes\nContenu.".utf8), named: "Notes.md", in: fixture.root)
        )
        let outcome = coordinator.apply(.attachment(deposit))
        #expect(outcome == .attachmentPlaced)
        #expect(coordinator.selection == .search)
        let chat = try #require(coordinator.session.chatViewModel)
        let controller = chat.attachmentController
        #expect(await waitFor { controller.attachments.count == 1 })
        #expect(chat.messages.isEmpty)
        #expect(!chat.isGenerating)
        controller.removeAll()
    }

    @Test("Plusieurs partages repris d'un coup : textes ajoutés à la suite du brouillon sans l'écraser, fichiers tous joints")
    func severalSharesAreAppended() async throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let coordinator = try makeCoordinator()
        coordinator.session.draft.text = "déjà là"
        let center = SystemRouteCenter(windowLauncher: nil)
        let deposits = try (1...3).map { index in
            try AttachmentFileVault.stageDeposit(of: try TestFiles.write(Data("# Note \(index)".utf8), named: "Note\(index).md", in: fixture.root))
        }
        deposits.forEach { center.submit(.attachment($0)) }
        center.submit(.draft("premier"))
        center.submit(.draft("second"))

        #expect(coordinator.consumeSystemRoutes(from: center, canUseOtherWindows: false, openInWindow: { _ in }) == 5)
        #expect(coordinator.session.draft.text == "déjà là premier second")
        let controller = try #require(coordinator.session.chatViewModel).attachmentController
        #expect(await waitFor { controller.attachments.count == 3 })
        #expect(controller.notices.isEmpty)
        controller.removeAll()
    }

    @Test("Trop de fichiers pour la conversation : l'excédent est refusé et la fenêtre le dit, avec les noms de tous les refusés")
    func tooManySharedFilesAreReported() async throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let coordinator = try makeCoordinator()
        let limit = FileAttachmentRules.maxAttachmentCount
        let center = SystemRouteCenter(windowLauncher: nil)
        for index in 1...(limit + 3) {
            let source = try TestFiles.write(Data("# Note \(index)".utf8), named: "Note\(index).md", in: fixture.root)
            center.submit(.attachment(try AttachmentFileVault.stageDeposit(of: source)))
        }
        center.submit(.notice(.truncatedText))

        coordinator.consumeSystemRoutes(from: center, canUseOtherWindows: false, openInWindow: { _ in })
        let controller = try #require(coordinator.session.chatViewModel).attachmentController
        let overflow = try #require(controller.notices.first { $0.message == FileAttachmentPresentation.tooManyFilesMessage(limit: limit) })
        #expect(overflow.fileNames == ["Note\(limit + 1).md", "Note\(limit + 2).md", "Note\(limit + 3).md"])
        #expect(controller.notices.count == 2, "l'information « texte coupé » reste affichée à côté")
        #expect(await waitFor { controller.attachments.count == limit })
        controller.removeAll()
    }

    @Test("Un fichier hors des dépôts n'est jamais joint par la fenêtre")
    func outsideDepositsIsIgnored() throws {
        let fixture = try RouteFixture(); defer { fixture.cleanUp() }
        let coordinator = try makeCoordinator()
        let own = try TestFiles.write(Data("secret".utf8), named: "perso.txt", in: fixture.root)
        #expect(coordinator.apply(.attachment(own)) == .ignored)
        #expect(coordinator.session.chatViewModel?.attachmentController.attachments.isEmpty ?? true)
        #expect(fixture.exists(own))
    }
}

@MainActor
@Suite("Partage — reprise à chaque passage au premier plan")
struct SharedInboxConsumerTests {
    private struct Setup {
        let fixture: RouteFixture
        let clock = TestClock()
        let inboxDirectory: URL
        let center: SystemRouteCenter
        let consumer: SharedInboxConsumer
        var inbox: SharedInbox {
            let clock = clock
            return SharedInbox(directory: inboxDirectory, now: { clock.date })
        }

        @MainActor
        init() throws {
            fixture = try RouteFixture()
            inboxDirectory = fixture.root.appendingPathComponent("share-inbox", isDirectory: true)
            center = SystemRouteCenter(windowLauncher: nil, depositRoot: fixture.depositRoot)
            let clock = clock
            consumer = SharedInboxConsumer(
                inbox: SharedInbox(directory: inboxDirectory, now: { clock.date }),
                center: center,
                depositRoot: fixture.depositRoot
            )
        }
    }

    @Test("Un texte partagé devient un BROUILLON : il n'est jamais envoyé")
    func textBecomesDraft() async throws {
        let setup = try Setup(); defer { setup.fixture.cleanUp() }
        try setup.inbox.add(text: "Pourquoi la mer est salée ?", fileAt: nil, displayName: nil)
        await setup.consumer.takeOver()
        #expect(setup.center.drain() == [.draft("Pourquoi la mer est salée ?")])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: setup.inboxDirectory.path)) ?? []).isEmpty)
    }

    @Test("Un PDF avec une question : le brouillon ET le fichier (dépôt) partent vers la fenêtre, la copie de l'App Group est effacée")
    func pdfWithQuestion() async throws {
        let setup = try Setup(); defer { setup.fixture.cleanUp() }
        let source = try TestFiles.write(SampleBytes.pdf(padding: 200), named: "Cours.pdf", in: setup.fixture.root)
        try setup.inbox.add(text: "Résume ce cours", fileAt: source, displayName: "Cours.pdf")
        await setup.consumer.takeOver()
        let routes = setup.center.drain()
        #expect(routes.count == 2)
        #expect(routes.contains(.draft("Résume ce cours")))
        let deposit: URL? = routes.compactMap { if case .attachment(let url) = $0 { url } else { nil } }.first
        #expect(deposit?.lastPathComponent == "Cours.pdf")
        #expect(deposit.map(setup.fixture.exists) == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: setup.inboxDirectory.path)) ?? []).isEmpty)
    }

    @Test("Reprise appelée deux fois de suite (deux scènes iPad) : une seule route")
    func concurrentTakeOverIsOnce() async throws {
        let setup = try Setup(); defer { setup.fixture.cleanUp() }
        try setup.inbox.add(text: "une seule fois", fileAt: nil, displayName: nil)
        async let first: Void = setup.consumer.takeOver()
        async let second: Void = setup.consumer.takeOver()
        _ = await (first, second)
        #expect(setup.center.drain() == [.draft("une seule fois")])
    }

    @Test("Boîte vide ou sans App Group : rien ne se passe, sans plantage")
    func nothingToTake() async throws {
        let setup = try Setup(); defer { setup.fixture.cleanUp() }
        await setup.consumer.takeOver()
        let noGroup = SharedInboxConsumer(inbox: nil, center: setup.center, depositRoot: setup.fixture.depositRoot)
        await noGroup.takeOver()
        noGroup.eraseAll()
        #expect(setup.center.drain().isEmpty)
    }

    @Test("« Tout effacer » : la boîte est vidée (entrées, fichiers, fichiers en cours d'écriture)")
    func eraseAllEmptiesTheInbox() async throws {
        let setup = try Setup(); defer { setup.fixture.cleanUp() }
        let source = try TestFiles.write(SampleBytes.pdf(), named: "a.pdf", in: setup.fixture.root)
        try setup.inbox.add(text: "t", fileAt: source, displayName: "a.pdf")
        try TestFiles.write(Data("x".utf8), named: "\(UUID().uuidString).part", in: setup.inboxDirectory)
        setup.consumer.eraseAll()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: setup.inboxDirectory.path)) ?? []).isEmpty)
        await setup.consumer.takeOver()
        #expect(setup.center.drain().isEmpty)
    }
}
