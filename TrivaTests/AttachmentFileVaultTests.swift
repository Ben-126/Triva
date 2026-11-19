//
//  AttachmentFileVaultTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M5) : le coffre des fichiers joints (copie, effacement par conversation, purge, dépôts).
//  Toujours dans un dossier temporaire de test, jamais le vrai coffre de l'app.
//

import Foundation
import Testing
@testable import Triva

/// Dossier temporaire jetable, supprimé en fin de test.
private func withTemporaryRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("VaultTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

private func writeFile(_ name: String, in folder: URL, contents: String = "contenu") throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite("Coffre de fichiers joints")
struct AttachmentFileVaultTests {
    @Test("La copie garde le nom et le contenu, dans le dossier de la session, et laisse l'original intact")
    func copyKeepsNameAndContent() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("notes.txt", in: root.appendingPathComponent("origine"), contents: "bonjour")
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let copy = try vault.copy(of: source)
            #expect(copy.lastPathComponent == "notes.txt")
            #expect(copy.path.hasPrefix(vault.sessionDirectory.path + "/"))
            #expect(try String(contentsOf: copy, encoding: .utf8) == "bonjour")
            #expect(exists(source))
        }
    }

    @Test("Deux fichiers de même nom ne se marchent pas dessus")
    func sameNameTwice() async throws {
        try await withTemporaryRoot { root in
            let first = try writeFile("a.txt", in: root.appendingPathComponent("un"), contents: "1")
            let second = try writeFile("a.txt", in: root.appendingPathComponent("deux"), contents: "2")
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let copyOne = try vault.copy(of: first)
            let copyTwo = try vault.copy(of: second)
            #expect(copyOne != copyTwo)
            #expect(try String(contentsOf: copyOne, encoding: .utf8) == "1")
            #expect(try String(contentsOf: copyTwo, encoding: .utf8) == "2")
        }
    }

    @Test("Un fichier trop gros n'est pas copié")
    func tooLargeIsRefused() async throws {
        try await withTemporaryRoot { root in
            let big = root.appendingPathComponent("gros.pdf")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(AttachmentFileVault.maxFileByteCount + 1)) // fichier creux, aucun octet réel
            try handle.close()
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            #expect(throws: AttachmentFileVaultError.tooLarge) { try vault.copy(of: big) }
            #expect(!exists(vault.sessionDirectory))
        }
    }

    @Test("Un dossier ou un fichier absent est refusé, sans copie")
    func directoryOrMissingIsRefused() async throws {
        try await withTemporaryRoot { root in
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            #expect(throws: AttachmentFileVaultError.unreadable) { try vault.copy(of: root) }
            #expect(throws: AttachmentFileVaultError.unreadable) { try vault.copy(of: root.appendingPathComponent("absent.pdf")) }
        }
    }

    @Test("remove(storedURL:) efface la copie, jamais un fichier hors du coffre")
    func removeOnlyInsideVault() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("rapport.md", in: root.appendingPathComponent("origine"))
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let copy = try vault.copy(of: source)
            vault.remove(storedURL: source) // fichier de l'utilisateur : intouchable
            #expect(exists(source))
            vault.remove(storedURL: nil)
            vault.remove(storedURL: copy)
            #expect(!exists(copy))
            #expect(!exists(copy.deletingLastPathComponent()))
        }
    }

    @Test("Un chemin avec « .. » ne sort pas du coffre")
    func removeIgnoresTraversal() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("secret.txt", in: root.appendingPathComponent("origine"))
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            _ = try vault.copy(of: source)
            let sneaky = vault.sessionDirectory.appendingPathComponent("../../origine/secret.txt")
            vault.remove(storedURL: sneaky)
            #expect(exists(source))
        }
    }

    @Test("removeAll efface la session et laisse les autres conversations")
    func removeAllKeepsOtherSessions() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("a.txt", in: root.appendingPathComponent("origine"))
            let coffre = root.appendingPathComponent("coffre")
            let mine = AttachmentFileVault(rootDirectory: coffre)
            let other = AttachmentFileVault(rootDirectory: coffre)
            let myCopy = try mine.copy(of: source)
            let otherCopy = try other.copy(of: source)
            mine.removeAll()
            #expect(!exists(myCopy))
            #expect(exists(otherCopy))
        }
    }

    @Test("purgeAll efface tout le coffre, dépôts compris")
    func purgeAllRemovesEverything() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("a.txt", in: root.appendingPathComponent("origine"))
            let coffre = root.appendingPathComponent("coffre")
            let vault = AttachmentFileVault(rootDirectory: coffre)
            _ = try vault.copy(of: source)
            _ = try AttachmentFileVault.stageDeposit(of: source, rootDirectory: coffre)
            AttachmentFileVault.purgeAll(rootDirectory: coffre)
            #expect(!exists(coffre))
            #expect(exists(source))
        }
    }

    // MARK: place

    @Test("place : un fichier lisible est copié et lu sur la copie")
    func placeCopiesSupportedFile() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("doc.json", in: root.appendingPathComponent("origine"), contents: "{}")
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let placement = await vault.place(source, isDeposit: false)
            #expect(placement.storedURL == placement.readURL)
            #expect(placement.readURL != source)
            #expect(exists(placement.readURL))
        }
    }

    @Test("place : un type que l'extracteur ne lit pas n'est pas copié")
    func placeSkipsUnsupportedType() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("archive.zip", in: root.appendingPathComponent("origine"))
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let placement = await vault.place(source, isDeposit: false)
            #expect(placement == AttachmentFilePlacement(readURL: source, storedURL: nil))
            #expect(!exists(vault.sessionDirectory))
        }
    }

    @Test("place : copie impossible, le fichier d'origine est lu tel quel, sans Coup d'œil")
    func placeFallsBackToOriginal() async throws {
        try await withTemporaryRoot { root in
            let missing = root.appendingPathComponent("absent.pdf")
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            let placement = await vault.place(missing, isDeposit: false)
            #expect(placement == AttachmentFilePlacement(readURL: missing, storedURL: nil))
        }
    }

    // MARK: Dépôts

    @Test("Un dépôt est copié sous <racine>/_deposits, puis adopté par déplacement (pas de recopie)")
    func depositThenAdopt() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("lettre.txt", in: root.appendingPathComponent("origine"), contents: "chère Ben")
            let coffre = root.appendingPathComponent("coffre")
            let deposit = try AttachmentFileVault.stageDeposit(of: source, rootDirectory: coffre)
            #expect(deposit.path.contains("/\(AttachmentFileVault.depositsFolderName)/"))
            #expect(deposit.lastPathComponent == "lettre.txt")

            let vault = AttachmentFileVault(rootDirectory: coffre)
            let placement = await vault.place(deposit, isDeposit: true)
            #expect(placement.storedURL != nil)
            #expect(!exists(deposit))
            #expect(try String(contentsOf: placement.readURL, encoding: .utf8) == "chère Ben")
            #expect(placement.readURL.path.hasPrefix(vault.sessionDirectory.path + "/"))
        }
    }

    @Test("Un nom proposé ne peut pas sortir du dépôt")
    func depositNameIsSafe() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("a.txt", in: root.appendingPathComponent("origine"))
            let coffre = root.appendingPathComponent("coffre")
            let deposit = try AttachmentFileVault.stageDeposit(of: source, named: "../../evasion.txt", rootDirectory: coffre)
            #expect(deposit.lastPathComponent == "evasion.txt")
            #expect(deposit.path.hasPrefix(coffre.path + "/\(AttachmentFileVault.depositsFolderName)/"))
        }
    }

    @Test("Un lien symbolique est suivi : le dépôt est une vraie copie de la cible, avec la limite de taille")
    func depositFollowsSymbolicLinks() async throws {
        try await withTemporaryRoot { root in
            let origin = root.appendingPathComponent("origine")
            let target = try writeFile("vrai.txt", in: origin, contents: "contenu réel")
            let link = origin.appendingPathComponent("raccourci.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let coffre = root.appendingPathComponent("coffre")

            let deposit = try AttachmentFileVault.stageDeposit(of: link, rootDirectory: coffre)
            #expect(deposit.lastPathComponent == "raccourci.txt")
            #expect(try deposit.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
            #expect(try String(contentsOf: deposit, encoding: .utf8) == "contenu réel")

            // Un lien vers un fichier de plus de 200 Mo n'échappe pas à la limite (fichier creux : aucun octet écrit).
            let big = origin.appendingPathComponent("gros.bin")
            #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(AttachmentFileVault.maxFileByteCount) + 1)
            try handle.close()
            let bigLink = origin.appendingPathComponent("gros-raccourci.bin")
            try FileManager.default.createSymbolicLink(at: bigLink, withDestinationURL: big)
            #expect(throws: AttachmentFileVaultError.tooLarge) {
                try AttachmentFileVault.stageDeposit(of: bigLink, rootDirectory: coffre)
            }
        }
    }

    @Test("discardDeposit efface un dépôt, mais jamais un fichier hors des dépôts")
    func discardOnlyDeposits() async throws {
        try await withTemporaryRoot { root in
            let source = try writeFile("a.txt", in: root.appendingPathComponent("origine"))
            let coffre = root.appendingPathComponent("coffre")
            let deposit = try AttachmentFileVault.stageDeposit(of: source, rootDirectory: coffre)
            AttachmentFileVault.discardDeposit(source, rootDirectory: coffre)
            #expect(exists(source))
            AttachmentFileVault.discardDeposit(deposit, rootDirectory: coffre)
            #expect(!exists(deposit))
            #expect(!exists(deposit.deletingLastPathComponent()))
        }
    }

    @Test("adopt refuse une URL hors des dépôts : le dossier de l'utilisateur reste intact")
    func adoptRefusesURLOutsideDeposits() async throws {
        try await withTemporaryRoot { root in
            let userFolder = root.appendingPathComponent("Documents", isDirectory: true)
            let report = try writeFile("rapport.pdf", in: userFolder)
            let vault = AttachmentFileVault(rootDirectory: root.appendingPathComponent("coffre"))
            #expect(throws: AttachmentFileVaultError.unreadable) { try vault.adopt(deposit: report) }
            #expect(exists(report))
            // Une URL qui tente de sortir des dépôts par `..` est refusée aussi.
            let sneaky = vault.rootDirectory
                .appendingPathComponent(AttachmentFileVault.depositsFolderName, isDirectory: true)
                .appendingPathComponent("../../Documents/rapport.pdf")
            #expect(throws: AttachmentFileVaultError.unreadable) { try vault.adopt(deposit: sneaky) }
            #expect(exists(report))
            // Le dossier des dépôts lui-même ou un fichier posé directement dedans ne sont pas des dépôts.
            let loose = try writeFile("vrac.txt", in: vault.rootDirectory.appendingPathComponent(AttachmentFileVault.depositsFolderName))
            #expect(throws: AttachmentFileVaultError.unreadable) { try vault.adopt(deposit: loose) }
            #expect(exists(loose))
        }
    }
}
