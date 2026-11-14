//
//  DeleteAllDataBenchTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

/// BANC D'ESSAI K7 (mission C2) : que fait `ModelContainer.deleteAllData()` ? Aucun changement de
/// comportement de l'app : ce fichier ne mesure que.
///
/// DÉSACTIVÉ PAR DÉFAUT : un plantage ne doit jamais entrer dans la suite principale. On l'active avec
/// la variable d'environnement `TRIVA_K7_BENCH` (via `TEST_RUNNER_TRIVA_K7_BENCH=<scénario>` pour
/// `xcodebuild`), un scénario par exécution, avec `-only-testing:TrivaTests/DeleteAllDataBenchTests` :
/// - `baseline` : suppression objet par objet + `save()` (ce que fait `deleteAll()` aujourd'hui) ;
/// - `deleteAllData` : `container.deleteAllData()` seul ;
/// - `reuse` : `deleteAllData()` puis réutilisation du `ChatHistoryStore` qui partage le conteneur.
///
/// Jamais sur les vraies données : tout vit dans un dossier jetable, sous un nom de configuration à part.
/// Chaque étape est écrite dans un journal (`TRIVA_K7_LOG`, sinon le dossier temporaire) AVANT d'être
/// jouée : si le processus plante, la dernière ligne dit où.
@MainActor
@Suite("Banc K7 : deleteAllData", .enabled(if: ProcessInfo.processInfo.environment["TRIVA_K7_BENCH"] != nil))
struct DeleteAllDataBenchTests {
    private static let marker = "K7MARQUEUR-\(UUID().uuidString)"

    @MainActor
    private struct Bench {
        let directory: URL
        let storeURL: URL
        let logURL: URL

        init(scenario: String) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "triva-k7-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appending(path: "Bench.store")
            if let path = ProcessInfo.processInfo.environment["TRIVA_K7_LOG"] {
                logURL = URL(fileURLWithPath: path)
            } else {
                logURL = FileManager.default.temporaryDirectory.appending(path: "k7-\(scenario).log")
            }
        }

        func log(_ line: String) {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.synchronize()
            } else {
                try? data.write(to: logURL)
            }
        }

        /// Occurrences du marqueur dans chaque fichier de la base (`.store`, `-wal`, `-shm`), en octets bruts.
        func scan(_ label: String) {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            let needle = Data(DeleteAllDataBenchTests.marker.utf8)
            var report: [String] = []
            for name in files {
                let data = (try? Data(contentsOf: directory.appending(path: name))) ?? Data()
                var count = 0
                var cursor = data.startIndex
                while let range = data.range(of: needle, in: cursor..<data.endIndex) {
                    count += 1
                    cursor = range.upperBound
                }
                report.append("\(name)=\(data.count)o/\(count)x")
            }
            log("SCAN \(label) : " + report.joined(separator: " | "))
        }

        func openContainer() throws -> ModelContainer {
            let schema = Schema(TrivaModelContainer.models)
            let configuration = ModelConfiguration(
                "TrivaK7Bench", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Une conversation de 20 messages dont chaque texte porte le marqueur.
    private func seed(_ store: ChatHistoryStore) throws {
        let conversation = try store.createConversation(title: "Sujet \(Self.marker)")
        for index in 0..<10 {
            try store.appendUserMessage(to: conversation, text: "Question \(index) \(Self.marker)")
            try store.appendAssistantMessage(to: conversation, text: "Réponse \(index) \(Self.marker)")
        }
    }

    private func scenario() -> String {
        ProcessInfo.processInfo.environment["TRIVA_K7_BENCH"] ?? ""
    }

    @Test("baseline : suppression objet par objet + save (comportement actuel de deleteAll)")
    func baseline() throws {
        guard scenario() == "baseline" else { return }
        let bench = try Bench(scenario: "baseline")
        bench.log("== baseline \(bench.directory.path)")
        var container: ModelContainer? = try bench.openContainer()
        var store: ChatHistoryStore? = ChatHistoryStore(container: try #require(container))
        try seed(try #require(store))
        bench.scan("après écriture")
        bench.log("deleteAll()…")
        try store?.deleteAll()
        bench.scan("juste après deleteAll()")
        store = nil
        container = nil
        bench.scan("après relâchement du conteneur")
        let reopened = try bench.openContainer()
        let count = try ModelContext(reopened).fetchCount(FetchDescriptor<StoredConversation>())
        bench.log("RELECTURE conversations=\(count)")
        bench.scan("après réouverture")
        bench.log("== fin baseline")
    }

    @Test("deleteAllData : fichiers lisibles après l'appel, immédiatement puis après fermeture")
    func deleteAllData() throws {
        guard scenario() == "deleteAllData" else { return }
        let bench = try Bench(scenario: "deleteAllData")
        bench.log("== deleteAllData \(bench.directory.path)")
        var container: ModelContainer? = try bench.openContainer()
        var store: ChatHistoryStore? = ChatHistoryStore(container: try #require(container))
        try seed(try #require(store))
        bench.scan("après écriture")
        bench.log("deleteAllData()…")
        try container?.deleteAllData()
        bench.log("deleteAllData() est revenu")
        bench.scan("juste après deleteAllData()")
        store = nil
        container = nil
        bench.scan("après relâchement du conteneur")
        let reopened = try bench.openContainer()
        let count = try ModelContext(reopened).fetchCount(FetchDescriptor<StoredConversation>())
        bench.log("RELECTURE conversations=\(count)")
        bench.scan("après réouverture")
        bench.log("== fin deleteAllData")
    }

    @Test("reuse : le ChatHistoryStore partagé survit-il à deleteAllData() ?")
    func reuse() throws {
        guard scenario() == "reuse" else { return }
        let bench = try Bench(scenario: "reuse")
        bench.log("== reuse \(bench.directory.path)")
        let container = try bench.openContainer()
        let store = ChatHistoryStore(container: container)
        try seed(store)
        bench.log("deleteAllData()…")
        try container.deleteAllData()
        bench.log("deleteAllData() est revenu ; lecture par le store partagé…")
        let after = try store.conversations()
        bench.log("LECTURE après deleteAllData : \(after.count) conversation(s)")
        bench.log("écriture par le store partagé…")
        _ = try store.createConversation(title: "Après effacement")
        bench.log("ÉCRITURE OK ; relecture : \(try store.conversations().count) conversation(s)")
        let fresh = ModelContext(container)
        bench.log("contexte neuf : \(try fresh.fetchCount(FetchDescriptor<StoredConversation>())) conversation(s)")
        bench.scan("fin")
        bench.log("== fin reuse")
    }
}
