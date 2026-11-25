//
//  ShareComposerModelTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : le modèle de la feuille « Rechercher avec Triva » (la vue elle-même est mince). Il lit
//  le partage, propose la question, écrit dans la boîte de l'App Group au bouton « Envoyer à Triva » ; rien ne part
//  ailleurs, et le dossier de travail de l'extension est effacé à la fin, quelle qu'elle soit.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Triva

@MainActor
private struct ModelFixture {
    let root: URL
    let staging: URL
    let inboxDirectory: URL
    let clock = TestClock()
    var inbox: SharedInbox {
        let clock = clock
        return SharedInbox(directory: inboxDirectory, now: { clock.date })
    }

    init() throws {
        root = try TestFiles.makeFolder("composer")
        staging = root.appendingPathComponent("staging", isDirectory: true)
        inboxDirectory = root.appendingPathComponent("share-inbox", isDirectory: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func textItem(_ text: String) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(object: text as NSString)]
        return item
    }

    func fileItem(_ data: Data, named name: String) throws -> NSExtensionItem {
        let url = try TestFiles.write(data, named: name, in: root)
        let provider = NSItemProvider()
        let type = try #require(UTType(filenameExtension: (name as NSString).pathExtension))
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        return item
    }

    func model(_ items: [NSExtensionItem], inbox: SharedInbox?? = nil) -> ShareComposerModel {
        let chosen = inbox ?? self.inbox
        return ShareComposerModel(items: items, stagingDirectory: staging, inbox: { chosen })
    }

    func stagingIsEmpty() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        return names.isEmpty
    }
}

@MainActor
@Suite("Partage — feuille « Rechercher avec Triva »")
struct ShareComposerModelTests {
    @Test("Texte partagé : la question est préremplie, modifiable, et part dans la boîte au bouton Envoyer")
    func textFlow() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([fixture.textItem("Qui a peint la Joconde ?")])
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.question == "Qui a peint la Joconde ?")
        #expect(model.canSend)

        model.question = "Qui a peint la Joconde, et quand ?"
        model.send()
        #expect(model.phase == .done(ShareMessages.confirmation(hasFile: false, hasQuestion: true)))
        let entry = try #require(fixture.inbox.validEntries().first)
        #expect(entry.text == "Qui a peint la Joconde, et quand ?")
        #expect(entry.file == nil)
    }

    @Test("Question vidée sans fichier : Envoyer est désactivé, rien n'est écrit")
    func blankQuestionCannotBeSent() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([fixture.textItem("une question")])
        await model.load()
        model.question = "  \n "
        #expect(!model.canSend)
        model.send()
        #expect(model.phase == .ready)
        #expect(fixture.inbox.validEntries().isEmpty)
    }

    @Test("PDF partagé : le fichier passe dans la boîte avec la question facultative, le dossier de travail est vidé")
    func pdfFlow() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let bytes = SampleBytes.pdf(padding: 400)
        let model = fixture.model([try fixture.fileItem(bytes, named: "Cours.pdf")])
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.file?.displayName == "Cours.pdf")
        #expect(model.question.isEmpty)
        #expect(model.canSend, "un fichier suffit, la question est facultative")

        model.question = "Résume ce cours"
        model.send()
        #expect(model.phase == .done(ShareMessages.confirmation(hasFile: true, hasQuestion: true)))
        let entry = try #require(fixture.inbox.validEntries().first)
        #expect(entry.text == "Résume ce cours")
        #expect(entry.file?.displayName == "Cours.pdf")
        #expect(try Data(contentsOf: fixture.inbox.payloadURL(of: entry)) == bytes)
        #expect(fixture.stagingIsEmpty())
    }

    @Test("Annuler : rien dans la boîte, dossier de travail vidé")
    func cancelCleansUp() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([try fixture.fileItem(SampleBytes.png(), named: "photo.png")])
        await model.load()
        #expect(!fixture.stagingIsEmpty())
        model.cancel()
        #expect(fixture.stagingIsEmpty())
        #expect(fixture.inbox.validEntries().isEmpty)
    }

    @Test("Fichier malveillant : message clair, rien n'est gardé nulle part")
    func maliciousFileIsRefused() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([try fixture.fileItem(SampleBytes.executable(), named: "facture.pdf")])
        await model.load()
        #expect(model.phase == .failed(ShareMessages.unsupportedFile))
        #expect(!model.canSend)
        #expect(fixture.stagingIsEmpty())
        #expect(fixture.inbox.validEntries().isEmpty)
    }

    @Test("Rien de lisible : « Triva n'a pas pu lire ce contenu. »")
    func nothingReadable() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([NSExtensionItem()])
        await model.load()
        #expect(model.phase == .failed("Triva n'a pas pu lire ce contenu."))
    }

    @Test("Sans App Group : l'envoi échoue avec un message clair, rien ne se perd en silence")
    func missingAppGroup() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([fixture.textItem("une question")], inbox: .some(nil))
        await model.load()
        model.send()
        #expect(model.phase == .failed(ShareMessages.cannotSave))
        #expect(fixture.stagingIsEmpty())
    }

    @Test("Un double toucher sur Envoyer n'écrit qu'une entrée")
    func doubleSend() async throws {
        let fixture = try ModelFixture(); defer { fixture.cleanUp() }
        let model = fixture.model([fixture.textItem("une seule fois")])
        await model.load()
        model.send()
        model.send()
        #expect(fixture.inbox.validEntries().count == 1)
    }

    @Test("Les textes de la feuille")
    func texts() {
        #expect(ShareMessages.unreadable == "Triva n'a pas pu lire ce contenu.")
        #expect(ShareMessages.unsupportedFile == "Triva ne lit pas ce type de fichier.")
        #expect(ShareMessages.tooLarge == "Ce fichier est trop volumineux pour être joint.")
        #expect(ShareMessages.confirmation(hasFile: false, hasQuestion: true) == "C'est prêt. Ouvre Triva : ta question t'attend dans la barre de saisie.")
        #expect(ShareMessages.confirmation(hasFile: true, hasQuestion: false) == "C'est prêt. Ouvre Triva : ton fichier t'attend dans la barre de saisie.")
        #expect(ShareMessages.confirmation(hasFile: true, hasQuestion: true) == "C'est prêt. Ouvre Triva : ton fichier et ta question t'attendent dans la barre de saisie.")
    }
}
