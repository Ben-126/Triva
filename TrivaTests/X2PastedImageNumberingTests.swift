//
//  X2PastedImageNumberingTests.swift
//  TrivaTests
//
//  X2 : deux images collées dans la MÊME seconde ne se refusent plus (compteur dans le nom).
//

import Foundation
import Testing
@testable import Triva

@Suite("Image collée — rang dans la seconde")
struct X2PastedImageNumberingTests {
    private let second = Date(timeIntervalSince1970: 1_795_000_000)
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    @Test("Le rang continue dans la même seconde et repart à 0 à la seconde suivante")
    func rankContinuesWithinASecond() {
        let numbering = PastedImageNumbering()
        #expect(numbering.reserve(count: 1, at: second) == 0)
        #expect(numbering.reserve(count: 3, at: second.addingTimeInterval(0.4)) == 1)
        #expect(numbering.reserve(count: 1, at: second.addingTimeInterval(0.9)) == 4)
        #expect(numbering.reserve(count: 1, at: second.addingTimeInterval(1.1)) == 0)
    }

    @Test("Deux collages d'une image dans la même seconde ont deux noms différents, le premier sans suffixe")
    func twoPastesInTheSameSecondGetDifferentNames() {
        let numbering = PastedImageNumbering()
        let names = (0..<2).map { _ in
            PastedImageNaming.fileName(
                date: second, index: numbering.reserve(count: 1, at: second), fileExtension: "png", timeZone: utc
            )
        }
        #expect(names[0] != names[1])
        #expect(!names[0].contains("("))
        #expect(names[1].hasSuffix("(2).png"))
        let plan = FileAttachmentRules.plan(
            for: names.map { URL(fileURLWithPath: "/dépôts/\($0)") }, existingFileNames: [], availableSlots: 5
        )
        #expect(plan.accepted.count == 2)
        #expect(plan.duplicateFileNames.isEmpty)
    }

    @Test("PasteImport : deux collages successifs de la même seconde ne reçoivent pas le même nom")
    func successivePastesAreNamedDifferently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("X2Paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let numbering = PastedImageNumbering()
        func paste() throws -> String {
            let staged = try AttachmentFileVault.stageDeposit(data: Data("x".utf8), named: "image.png", rootDirectory: root)
            let items = PasteImport.uniquelyNamed(
                [.image(staged)], imagePrefix: "Image collée", date: second, depositRoot: root, numbering: numbering
            )
            guard case .image(let url) = try #require(items.first) else { throw CocoaError(.fileReadUnknown) }
            return url.lastPathComponent
        }
        let firstName = try paste()
        let secondName = try paste()
        #expect(firstName != secondName)
    }

    @Test("PasteImport : un collage de deux images garde des noms distincts")
    func twoImagesOfOnePasteAreDistinct() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("X2Paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try (0..<2).map { _ in
            try AttachmentFileVault.stageDeposit(data: Data("x".utf8), named: "image.png", rootDirectory: root)
        }
        let items = PasteImport.uniquelyNamed(
            staged.map { .image($0) }, imagePrefix: "Photo", date: second, depositRoot: root, numbering: PastedImageNumbering()
        )
        let names = items.compactMap { item -> String? in
            if case .image(let url) = item { url.lastPathComponent } else { nil }
        }
        #expect(Set(names).count == 2)
    }

    #if os(macOS)
    @Test("Mac : deux images collées dans la même seconde, deux noms différents")
    func pasteboardPayloadUsesTheCounter() async throws {
        let numbering = PastedImageNumbering()
        var payload = MacPastePayload()
        payload.imageData = Data("png".utf8)
        payload.imageFormat = PastedImageFormat.all[0]
        let first = await payload.attachableItems(date: second, numbering: numbering)
        let secondItems = await payload.attachableItems(date: second, numbering: numbering)
        defer { (first + secondItems).forEach { if case .image(let url) = $0 { AttachmentFileVault.discardDeposit(url) } } }
        guard case .image(let a)? = first.first, case .image(let b)? = secondItems.first else {
            Issue.record("attendu .image")
            return
        }
        #expect(a.lastPathComponent != b.lastPathComponent)
    }
    #endif
}

@Suite("Coffre — purge totale")
struct X2VaultPurgeTests {
    @Test("Un dossier absent compte comme purgé")
    func missingFolderIsPurged() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("X2Purge-\(UUID().uuidString)")
        #expect(AttachmentFileVault.purgeAll(rootDirectory: root) == true)
    }

    @Test("Un dossier présent est supprimé : vrai")
    func existingFolderIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("X2Purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        #expect(AttachmentFileVault.purgeAll(rootDirectory: root) == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Une copie impossible à supprimer : faux, la copie reste")
    func refusedDeletionIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("X2Purge-\(UUID().uuidString)", isDirectory: true)
        let locked = root.appendingPathComponent("_deposits", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("a.txt"))
        // Sous-dossier en lecture seule : le fichier qu'il contient ne peut pas être retiré.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(AttachmentFileVault.purgeAll(rootDirectory: root) == false)
        #expect(FileManager.default.fileExists(atPath: locked.appendingPathComponent("a.txt").path))
    }

    @Test("Dossier du coffre impossible à retirer mais vidé : aucune copie ne reste, donc purgé")
    func emptiedFolderCountsAsPurged() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("X2PurgeParent-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("coffre", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        #expect(AttachmentFileVault.purgeAll(rootDirectory: root) == true)
    }
}
