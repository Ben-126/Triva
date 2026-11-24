//
//  WidgetSnapshotTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission C) : le petit fichier JSON que l'app écrit pour le widget, et le magasin de fichiers de
//  l'App Group qui le porte. Tout se passe dans un dossier temporaire : jamais le vrai App Group.
//

import Foundation
import Testing
@testable import Triva

/// Dossier temporaire jetable pour un test.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "TrivaWidgetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Magasin de fichiers de l'App Group")
struct AppGroupFileStoreTests {
    @Test("Écrire puis relire rend les mêmes octets, et crée les dossiers manquants")
    func roundTripCreatesFolders() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupFileStore(directory: root.appending(path: "TrivaShared", directoryHint: .isDirectory))

        try store.write(Data("bonjour".utf8), to: "a.json")
        try store.write(Data("sous-dossier".utf8), to: "share-inbox/b.json")

        #expect(try store.read("a.json") == Data("bonjour".utf8))
        #expect(try store.read("share-inbox/b.json") == Data("sous-dossier".utf8))
    }

    @Test("Écrire une seconde fois remplace le contenu")
    func overwriteReplaces() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupFileStore(directory: root)

        try store.write(Data("un".utf8), to: "a.json")
        try store.write(Data("deux".utf8), to: "a.json")

        #expect(try store.read("a.json") == Data("deux".utf8))
    }

    @Test("Un fichier absent se lit comme nil ; le supprimer ne lève rien")
    func missingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupFileStore(directory: root)

        #expect(try store.read("absent.json") == nil)
        #expect(store.exists("absent.json") == false)
        try store.remove("absent.json")
    }

    @Test("Supprimer un fichier présent le retire vraiment")
    func removeExisting() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupFileStore(directory: root)
        try store.write(Data("x".utf8), to: "a.json")
        #expect(store.exists("a.json"))

        try store.remove("a.json")

        #expect(store.exists("a.json") == false)
    }

    @Test("Un chemin qui sortirait du dossier est refusé, en lecture, écriture et suppression",
          arguments: ["", "..", "../a.json", "a/../../b.json", "/etc/passwd", "a//b.json", "./a.json", "a/", " "])
    func unsafePathsRejected(path: String) throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupFileStore(directory: root)

        #expect(throws: AppGroupFileStore.StoreError.invalidPath) { try store.write(Data("x".utf8), to: path) }
        #expect(throws: AppGroupFileStore.StoreError.invalidPath) { try store.read(path) }
        #expect(throws: AppGroupFileStore.StoreError.invalidPath) { try store.remove(path) }
        #expect(store.exists(path) == false)
    }

    @Test("Écrire sous un « dossier » qui est en fait un fichier échoue avec une erreur claire")
    func writeFailureIsReported() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "bloque")
        try Data("je suis un fichier".utf8).write(to: blocker)
        let store = AppGroupFileStore(directory: blocker)

        #expect(throws: AppGroupFileStore.StoreError.self) { try store.write(Data("x".utf8), to: "a.json") }
    }
}

@Suite("Instantané du widget")
struct WidgetSnapshotTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Titre

    @Test("Un titre court est gardé tel quel")
    func shortTitleKept() {
        #expect(WidgetSnapshot.displayTitle("Météo à Lyon") == "Météo à Lyon")
    }

    @Test("Retours à la ligne, tabulations et espaces multiples deviennent un seul espace, bords retirés")
    func whitespaceCollapsed() {
        #expect(WidgetSnapshot.displayTitle("  Quel  temps\nfait-il\t demain ?  \n") == "Quel temps fait-il demain ?")
    }

    @Test("80 caractères pile : gardé ; 81 : coupé à 80 au total, avec « … »")
    func titleCappedAtEighty() {
        let exact = String(repeating: "a", count: WidgetSnapshot.maxTitleLength)
        #expect(WidgetSnapshot.displayTitle(exact) == exact)

        let cut = WidgetSnapshot.displayTitle(exact + "b")
        #expect(cut.count == WidgetSnapshot.maxTitleLength)
        #expect(cut.hasSuffix("…"))
        #expect(cut.hasPrefix(String(repeating: "a", count: 79)))
    }

    @Test("La coupe respecte les caractères entiers (accents, emoji composés), jamais au milieu")
    func cutRespectsGraphemes() {
        let family = "👨‍👩‍👧‍👦"
        let title = String(repeating: family, count: 90)
        let cut = WidgetSnapshot.displayTitle(title)
        #expect(cut.count == WidgetSnapshot.maxTitleLength)
        #expect(cut == String(repeating: family, count: 79) + "…")
    }

    @Test("La coupe ne laisse pas d'espace avant « … »")
    func noSpaceBeforeEllipsis() {
        let title = String(repeating: "a", count: 78) + " bbbb"
        let cut = WidgetSnapshot.displayTitle(title)
        #expect(cut == String(repeating: "a", count: 78) + "…")
    }

    @Test("Titre vide ou blanc : texte de repli")
    func emptyTitleFallback() {
        #expect(WidgetSnapshot.displayTitle("") == WidgetSnapshot.untitledFallback)
        #expect(WidgetSnapshot.displayTitle(" \n\t ") == WidgetSnapshot.untitledFallback)
    }

    // MARK: Construction

    @Test("Instantané d'une conversation : titre nettoyé, date arrondie à la seconde, version courante")
    func buildsFromConversation() {
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.789)
        let snapshot = WidgetSnapshot(conversationID: id, title: "  Bonjour\n", updatedAt: fractional)

        #expect(snapshot.version == WidgetSnapshot.currentVersion)
        #expect(snapshot.conversation?.id == id)
        #expect(snapshot.conversation?.title == "Bonjour")
        #expect(snapshot.conversation?.updatedAt == date)
    }

    @Test("Instantané vide : aucune conversation")
    func emptySnapshot() {
        #expect(WidgetSnapshot.empty.conversation == nil)
        #expect(WidgetSnapshot.empty.version == WidgetSnapshot.currentVersion)
    }

    // MARK: Magasin

    private func makeStore() throws -> (WidgetSnapshotStore, URL) {
        let root = try makeTempDirectory()
        return (WidgetSnapshotStore(files: AppGroupFileStore(directory: root)), root)
    }

    @Test("Aller-retour JSON : ce qu'on enregistre est ce qu'on relit")
    func jsonRoundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = WidgetSnapshot(conversationID: id, title: "Recette de crêpes", updatedAt: date)

        try store.save(snapshot)

        #expect(store.load() == snapshot)
        #expect(store.exists)
    }

    @Test("Aller-retour d'un instantané vide")
    func emptyRoundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(.empty)

        #expect(store.load() == .empty)
    }

    @Test("Aucun fichier : load rend nil")
    func noFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.load() == nil)
        #expect(store.exists == false)
    }

    @Test("Fichier corrompu : ignoré (nil) ET supprimé, sans plantage",
          arguments: ["pas du json", "", "{", "{\"version\":1,\"conversation\":{\"id\":\"x\"}}", "[1,2,3]"])
    func corruptedFileIsIgnoredAndRemoved(content: String) throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.files.write(Data(content.utf8), to: WidgetSnapshot.fileName)

        #expect(store.load() == nil)
        #expect(store.files.exists(WidgetSnapshot.fileName) == false)
    }

    @Test("Version inconnue (plus récente) : ignorée sans plantage, fichier laissé en place")
    func unknownVersionIgnored() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let future = #"{"version":99,"conversation":null}"#
        try store.files.write(Data(future.utf8), to: WidgetSnapshot.fileName)

        #expect(store.load() == nil)
        #expect(store.files.exists(WidgetSnapshot.fileName))
    }

    @Test("delete retire le fichier ; deux fois de suite ne lève rien")
    func deleteIsIdempotent() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.empty)

        try store.delete()
        try store.delete()

        #expect(store.exists == false)
    }

    @Test("Le JSON écrit ne contient que la version, l'identifiant, le titre et la date")
    func jsonShape() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(WidgetSnapshot(conversationID: id, title: "Titre", updatedAt: date))

        let data = try #require(try store.files.read(WidgetSnapshot.fileName))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let conversation = try #require(object["conversation"] as? [String: Any])

        #expect(Set(object.keys) == ["version", "conversation"])
        #expect(Set(conversation.keys) == ["id", "title", "updatedAt"])
    }
}

@Suite("Contenu du widget Recherche rapide")
struct QuickSearchContentTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!

    @Test("Pas de fichier (réglage éteint, ou rien d'écrit) : vue neutre, sans phrase sur l'historique")
    func noSnapshotIsNeutral() {
        #expect(QuickSearchContent(snapshot: nil) == .neutral)
    }

    @Test("Instantané vide (réglage allumé, historique vide) : « aucune recherche »")
    func emptySnapshotIsNoHistory() {
        #expect(QuickSearchContent(snapshot: .empty) == .noHistory)
    }

    @Test("Instantané avec une conversation : son identifiant et son titre")
    func conversationSnapshot() {
        let snapshot = WidgetSnapshot(conversationID: id, title: "Recette de crêpes", updatedAt: .now)
        #expect(QuickSearchContent(snapshot: snapshot) == .conversation(id: id, title: "Recette de crêpes"))
    }

    @Test("Le toucher « Nouvelle question » est l'URL triva://new, que l'app reconnaît")
    func newQuestionURLRoundTrips() throws {
        let content = QuickSearchContent.neutral
        let url = try #require(content.newQuestionURL)
        #expect(url.absoluteString == "triva://new")
        #expect(TrivaURLRoute.parse(url) == .newQuestion(.keyboard))
    }

    @Test("Le toucher « Reprendre » n'existe que pour une conversation, et mène à elle")
    func resumeURLOnlyForConversation() throws {
        #expect(QuickSearchContent.neutral.resumeURL == nil)
        #expect(QuickSearchContent.noHistory.resumeURL == nil)
        let url = try #require(QuickSearchContent.conversation(id: id, title: "x").resumeURL)
        #expect(TrivaURLRoute.parse(url) == .conversation(id))
    }

    @Test("Seule une conversation expose un titre")
    func titleOnlyForConversation() {
        #expect(QuickSearchContent.neutral.lastTitle == nil)
        #expect(QuickSearchContent.noHistory.lastTitle == nil)
        #expect(QuickSearchContent.conversation(id: id, title: "Sujet").lastTitle == "Sujet")
    }
}
