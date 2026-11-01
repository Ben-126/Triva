//
//  FileAttachmentPickerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Triva

// MARK: - Fabriques (toutes privées : d'autres fichiers de tests déclarent
// déjà `FakePreparer`, `pollUntil`, `fakeURL`…)

private func pickerURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: "/fichiers-factices").appendingPathComponent(fileName)
}

private func pickerAttachment(
    _ fileName: String,
    kind: AttachmentKind,
    pageCount: Int? = nil,
    isTruncated: Bool,
    pageRanges: [ClosedRange<Int>?] = [nil]
) -> IndexedAttachment {
    IndexedAttachment(
        fileName: fileName,
        kind: kind,
        pageCount: pageCount,
        characterCount: 100,
        isTruncated: isTruncated,
        isCopyRestricted: false,
        chunks: pageRanges.enumerated().map { AttachmentChunk(index: $0.offset, text: "Fragment \($0.offset)", pageRange: $0.element) }
    )
}

/// Lectures commencées par le préparateur factice, dans l'ordre.
private actor PickerTestLog {
    private(set) var startedFileNames: [String] = []
    private(set) var limits: [Int] = []

    func recordStart(_ fileName: String, limit: Int) {
        startedFileNames.append(fileName)
        limits.append(limit)
    }
}

/// Porte qui retient une lecture « en cours » jusqu'à son ouverture.
private actor PickerTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Préparateur factice, sans disque ni PDF, piloté par le nom : `lent…`
/// attend la porte, `scan…` lève `noExtractableText`, les autres consomment
/// `consumedCharacters` (borné par la limite reçue).
private struct PickerFakePreparer: AttachmentPreparing {
    let log: PickerTestLog
    var gate: PickerTestGate?
    var consumedCharacters = 10

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        let fileName = url.lastPathComponent
        await log.recordStart(fileName, limit: characterLimit)
        if fileName.hasPrefix("lent"), let gate {
            await gate.wait()
        }
        if fileName.hasPrefix("scan") {
            throw AttachmentExtractionError.noExtractableText(pageCount: 3)
        }
        return IndexedAttachment(
            fileName: fileName,
            kind: .plainText,
            pageCount: nil,
            characterCount: min(consumedCharacters, characterLimit),
            isTruncated: false,
            isCopyRestricted: false,
            chunks: [AttachmentChunk(index: 0, text: "Contenu de \(fileName)", pageRange: nil)]
        )
    }
}

// MARK: - Règles

@Suite("Pièces jointes — règles du sélecteur")
struct FileAttachmentRulesTests {
    @Test("Chaque format lu par l'extracteur est proposé par le sélecteur", arguments: zip(
        ["pdf", "txt", "log", "swift", "md", "markdown", "csv", "tsv", "json"],
        [AttachmentKind.pdf, .plainText, .plainText, .plainText, .markdown, .markdown, .csv, .csv, .json]
    ))
    func everyExtractableTypeIsSelectable(fileExtension: String, kind: AttachmentKind) throws {
        let type = try #require(UTType(filenameExtension: fileExtension))

        #expect(FileAttachmentRules.accepts(type))
        #expect(AttachmentKind(fileName: "fichier.\(fileExtension)") == kind)
    }

    @Test("Balisage, documents Office, images et archives ne sont pas proposés", arguments: [
        "html", "rtf", "xml", "docx", "png", "zip",
    ])
    func unreadableTypesAreNotSelectable(fileExtension: String) throws {
        let type = try #require(UTType(filenameExtension: fileExtension))

        #expect(!FileAttachmentRules.accepts(type))
        #expect(AttachmentKind(fileName: "fichier.\(fileExtension)") == nil)
    }

    @Test("Liste sans doublon, sans le type générique `public.text`, JSON compris")
    func allowedTypesAreDistinctAndPrecise() {
        let identifiers = FileAttachmentRules.allowedContentTypes.map(\.identifier)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(!FileAttachmentRules.allowedContentTypes.contains(.text))
        #expect(FileAttachmentRules.allowedContentTypes.contains(.json))
    }

    @Test("Doublons repérés sans tenir compte de la casse, contre l'existant et dans la sélection")
    func planFlagsCaseInsensitiveDuplicates() {
        let urls = ["Notes.md", "rapport.pdf", "NOTES.MD", "Rapport.PDF"].map(pickerURL)

        let plan = FileAttachmentRules.plan(for: urls, existingFileNames: ["notes.md"], availableSlots: 5)

        #expect(plan.accepted.map(\.lastPathComponent) == ["rapport.pdf"])
        #expect(plan.duplicateFileNames == ["Notes.md", "NOTES.MD", "Rapport.PDF"])
        #expect(plan.overflowFileNames.isEmpty)
    }

    @Test("« é » composé ou décomposé : même nom, donc doublon")
    func planComparesCanonicallyEquivalentNames() {
        let plan = FileAttachmentRules.plan(
            for: [pickerURL("re\u{301}sume\u{301}.txt")],
            existingFileNames: ["r\u{E9}sum\u{E9}.txt"],
            availableSlots: 5
        )

        #expect(plan.accepted.isEmpty)
        #expect(plan.duplicateFileNames.count == 1)
    }

    @Test("Au-delà des places libres : excédent, dans l'ordre de la sélection ; places négatives = 0")
    func planMovesExtraFilesToOverflow() {
        let urls = ["a.txt", "b.txt", "c.txt", "d.txt"].map(pickerURL)

        let plan = FileAttachmentRules.plan(for: urls, existingFileNames: [], availableSlots: 2)
        let negative = FileAttachmentRules.plan(for: [pickerURL("a.txt")], existingFileNames: [], availableSlots: -3)

        #expect(plan.accepted.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(plan.overflowFileNames == ["c.txt", "d.txt"])
        #expect(negative.accepted.isEmpty)
        #expect(negative.overflowFileNames == ["a.txt"])
    }
}

// MARK: - Présentation

@Suite("Pièces jointes — présentation")
struct FileAttachmentPresentationTests {
    @Test("Nom sur une ligne : sauts de ligne et contrôles remplacés, blancs fusionnés")
    func displayNameFlattensLineBreaks() {
        #expect(FileAttachmentPresentation.displayName(for: "notes\nde\r\ncours\t final.md") == "notes de cours final.md")
    }

    @Test("Marques bidirectionnelles retirées : l'ordre affiché ne peut plus tromper")
    func displayNameStripsBidirectionalControls() {
        #expect(FileAttachmentPresentation.displayName(for: "rapport\u{202E}fdp.exe") == "rapportfdp.exe")
        #expect(FileAttachmentPresentation.displayName(for: "\u{200F}a\u{2066}b\u{2069}\u{061C}.txt") == "ab.txt")
    }

    @Test("Nom vide, ou fait de blancs et de marques : libellé neutre")
    func displayNameFallsBackForBlankNames() {
        #expect(FileAttachmentPresentation.displayName(for: "") == FileAttachmentPresentation.untitledFileName)
        #expect(FileAttachmentPresentation.displayName(for: " \n\u{202E} ") == FileAttachmentPresentation.untitledFileName)
    }

    @Test("Raccourci au milieu : extension gardée, longueur exactement la limite")
    func shortenedNameKeepsExtension() {
        let short = FileAttachmentPresentation.shortenedName("rapport-annuel-2025-version-definitive-relue.pdf", maxLength: 24)

        #expect(short == "rapport-annue…-relue.pdf")
        #expect(short.count == 24)
    }

    @Test("Nom court inchangé ; extension trop longue traitée comme du nom ; accents jamais coupés")
    func shortenedNameEdgeCases() {
        let longExtension = FileAttachmentPresentation.shortenedName("archive.extensiontreslongue", maxLength: 16)
        let accented = FileAttachmentPresentation.shortenedName(String(repeating: "e\u{301}", count: 30) + ".txt", maxLength: 24)

        #expect(FileAttachmentPresentation.shortenedName("notes.md", maxLength: 24) == "notes.md")
        #expect(longExtension == "archive.ex…ongue")
        #expect(accented.count == 24)
        #expect(accented.hasSuffix(".txt"))
        #expect(accented.unicodeScalars.filter { $0 == "\u{301}" }.count == 19)
    }

    @Test("Pas tronqué : aucune note")
    func noNoteWhenComplete() {
        let attachment = pickerAttachment("cours.pdf", kind: .pdf, pageCount: 4, isTruncated: false, pageRanges: [1...4])

        #expect(FileAttachmentPresentation.truncationNote(for: attachment) == nil)
    }

    @Test("Fichier texte tronqué : début du fichier seulement")
    func textFileNote() {
        let note = FileAttachmentPresentation.truncationNote(for: pickerAttachment("notes.txt", kind: .plainText, isTruncated: true))

        #expect(note?.summary == "Début du fichier seulement")
        #expect(note?.detail == "Seul le début de ce fichier sera utilisé pour répondre.")
    }

    @Test("PDF tronqué sans page connue : début du document seulement")
    func pdfWithoutKnownPagesNote() {
        let withoutRanges = pickerAttachment("a.pdf", kind: .pdf, pageCount: 10, isTruncated: true, pageRanges: [nil])
        let withoutCount = pickerAttachment("b.pdf", kind: .pdf, pageCount: nil, isTruncated: true, pageRanges: [1...3])

        #expect(FileAttachmentPresentation.truncationNote(for: withoutRanges)?.summary == "Début du document seulement")
        #expect(FileAttachmentPresentation.truncationNote(for: withoutCount)?.summary == "Début du document seulement")
    }

    @Test("PDF coupé dans sa dernière page : seule la fin manque")
    func pdfCutInsideLastPage() {
        let attachment = pickerAttachment("a.pdf", kind: .pdf, pageCount: 3, isTruncated: true, pageRanges: [1...2, 2...3])

        #expect(FileAttachmentPresentation.truncationNote(for: attachment)?.summary == "Fin du document non lue")
    }

    @Test("PDF lu sur sa première page seulement")
    func pdfFirstPageOnly() {
        let attachment = pickerAttachment("a.pdf", kind: .pdf, pageCount: 40, isTruncated: true, pageRanges: [1...1])
        let note = FileAttachmentPresentation.truncationNote(for: attachment)

        #expect(note?.summary == "Page 1 sur 40 seulement")
        #expect(note?.detail == "Seule la première page sur 40 sera utilisée pour répondre.")
    }

    @Test("PDF lu jusqu'à la page 16 sur 120, quel que soit l'ordre des fragments")
    func pdfReadUpToAPage() {
        let attachment = pickerAttachment("a.pdf", kind: .pdf, pageCount: 120, isTruncated: true, pageRanges: [15...16, 1...2, 8...9])
        let note = FileAttachmentPresentation.truncationNote(for: attachment)

        #expect(note?.summary == "Pages 1 à 16 sur 120 seulement")
        #expect(note?.detail == "Seules les pages 1 à 16 sur 120 seront utilisées pour répondre.")
    }

    @Test("Échecs : annulation muette, erreurs connues relayées, inconnue au texte fixe")
    func failureMessages() {
        #expect(FileAttachmentPresentation.failureMessage(for: CancellationError()) == nil)
        #expect(FileAttachmentPresentation.failureMessage(for: AttachmentExtractionError.fileUnreadable)
            == AttachmentExtractionError.fileUnreadable.userFacingMessage)
        #expect(FileAttachmentPresentation.failureMessage(for: AttachmentStoreError.characterBudgetExhausted)
            == AttachmentStoreError.characterBudgetExhausted.userFacingMessage)
        #expect(FileAttachmentPresentation.failureMessage(for: URLError(.cannotOpenFile))
            == FileAttachmentPresentation.unexpectedFailureMessage)
    }

    @Test("Seule la fermeture du sélecteur par l'utilisateur est ignorée")
    func userCancellationOnly() {
        #expect(FileAttachmentPresentation.isUserCancellation(CocoaError(.userCancelled)))
        #expect(!FileAttachmentPresentation.isUserCancellation(CocoaError(.fileReadNoPermission)))
        #expect(!FileAttachmentPresentation.isUserCancellation(CancellationError()))
    }

    @Test("Panneau d'ouverture : singulier, pluriel, jamais « 0 document »")
    func dialogMessages() {
        #expect(FileAttachmentPresentation.dialogMessage(remainingSlots: 1).contains("un document"))
        #expect(FileAttachmentPresentation.dialogMessage(remainingSlots: 3).contains("jusqu'à 3 documents"))
        #expect(FileAttachmentPresentation.dialogMessage(remainingSlots: 0) == FileAttachmentPresentation.dialogMessage(remainingSlots: 1))
    }

    @Test("VoiceOver : nom nettoyé puis troncature ; annonces avec les fichiers en tête")
    func accessibilityTexts() {
        let note = FileAttachmentTruncationNote(summary: "Début du fichier seulement", detail: "Seul le début de ce fichier sera utilisé pour répondre.")
        let notice = FileAttachmentNotice(fileNames: ["a.txt", "b\n.txt"], message: "Déjà joint à cette conversation.")

        #expect(FileAttachmentPresentation.attachedAccessibilityLabel(fileName: "a\nb.txt", note: nil) == "a b.txt")
        #expect(FileAttachmentPresentation.attachedAccessibilityLabel(fileName: "a.txt", note: note)
            == "a.txt. Seul le début de ce fichier sera utilisé pour répondre.")
        #expect(FileAttachmentPresentation.announcement(for: notice) == "a.txt, b .txt. Déjà joint à cette conversation.")
        #expect(FileAttachmentPresentation.announcement(for: FileAttachmentNotice(fileNames: [], message: "M")) == "M")
    }
}

// MARK: - Contrôleur

/// `@MainActor` : le contrôleur et `AttachmentStore` sont isolés au main
/// actor. `LexicalSimilarityScorer` : la recherche n'est jamais exercée ici,
/// inutile de charger un modèle `NaturalLanguage`.
@MainActor
@Suite("Pièces jointes — contrôleur du sélecteur")
struct FileAttachmentControllerTests {
    /// Attente coopérative bornée. `Task.sleep` et JAMAIS `Task.yield()` : avec
    /// l'isolation MainActor, `yield()` ne garantit pas que la tâche de lecture
    /// progresse (piège documenté dans `ChatViewModelTests`).
    /// 30 s et pas 5 : seule, la suite passe en quelques millisecondes, mais au
    /// sein de la suite complète (des centaines de tests `@MainActor` en
    /// parallèle) 5 s expiraient (7 faux échecs le 2026-10-04). La borne ne
    /// coûte rien quand tout va bien : la boucle sort dès que la condition tient.
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    private func makeController(
        preparer: PickerFakePreparer,
        totalCharacterBudget: Int = AttachmentStore.defaultTotalCharacterBudget,
        maxCharactersPerAttachment: Int = AttachmentTextExtractor.defaultMaxCharacterCount,
        maxAttachmentCount: Int = FileAttachmentRules.maxAttachmentCount
    ) -> FileAttachmentController {
        let store = AttachmentStore(
            scorer: LexicalSimilarityScorer(),
            preparer: preparer,
            totalCharacterBudget: totalCharacterBudget,
            maxCharactersPerAttachment: maxCharactersPerAttachment
        )
        return FileAttachmentController(store: store, maxAttachmentCount: maxAttachmentCount)
    }

    @Test("Lecture séquentielle : trois petits fichiers tiennent dans un budget que des lectures parallèles épuiseraient")
    func readsFilesOneAfterAnother() async {
        let log = PickerTestLog()
        let controller = makeController(
            preparer: PickerFakePreparer(log: log, consumedCharacters: 10),
            totalCharacterBudget: 100,
            maxCharactersPerAttachment: 60
        )

        controller.enqueue(["a.txt", "b.txt", "c.txt"].map(pickerURL))

        #expect(controller.pendingAttachments.map(\.fileName) == ["a.txt", "b.txt", "c.txt"])
        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["a.txt", "b.txt", "c.txt"])
        #expect(controller.notices.isEmpty)
        // En parallèle, les réservations auraient été 60, 40 puis un refus.
        #expect(await log.limits == [60, 60, 60])
    }

    @Test("Budget épuisé en cours de file : un seul message nomme le fichier refusé et ceux abandonnés")
    func exhaustedBudgetAbandonsRemainingQueue() async {
        let log = PickerTestLog()
        let controller = makeController(
            preparer: PickerFakePreparer(log: log, consumedCharacters: 100),
            totalCharacterBudget: 100,
            maxCharactersPerAttachment: 100
        )

        controller.enqueue(["a.txt", "b.txt", "c.txt", "d.txt"].map(pickerURL))

        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["a.txt"])
        #expect(controller.notices.map(\.fileNames) == [["b.txt", "c.txt", "d.txt"]])
        #expect(controller.notices.first?.message == AttachmentStoreError.characterBudgetExhausted.userFacingMessage)
        #expect(await log.startedFileNames == ["a.txt"])
        #expect(!controller.canAttachMore)
    }

    @Test("Fichier retiré pendant sa lecture : ni capsule ni message, la file continue")
    func removingFileDuringReadDiscardsItsResult() async throws {
        let log = PickerTestLog()
        let gate = PickerTestGate()
        let controller = makeController(preparer: PickerFakePreparer(log: log, gate: gate))
        controller.enqueue(["lent.txt", "b.txt"].map(pickerURL))
        #expect(await waitUntil { await log.startedFileNames == ["lent.txt"] })
        let slowFile = try #require(controller.pendingAttachments.first)

        controller.removePendingAttachment(id: slowFile.id)
        #expect(controller.pendingAttachments.map(\.fileName) == ["b.txt"])
        await gate.open()

        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["b.txt"])
        #expect(controller.notices.isEmpty)
    }

    @Test("Nouvelle conversation pendant une lecture : ni la lecture en cours ni la file ne s'attachent")
    func removeAllDuringReadAttachesNothing() async {
        let log = PickerTestLog()
        let gate = PickerTestGate()
        let controller = makeController(preparer: PickerFakePreparer(log: log, gate: gate))
        controller.enqueue(["lent.txt", "b.txt", "c.txt"].map(pickerURL))
        #expect(await waitUntil { await log.startedFileNames == ["lent.txt"] })

        controller.removeAll()
        #expect(controller.isEmpty)
        await gate.open()
        // Lu après la lecture abandonnée, par la même file : une fois qu'il est
        // joint, le sort de tous les fichiers précédents est réglé.
        controller.enqueue([pickerURL("nouveau.txt")])

        #expect(await waitUntil { !controller.attachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["nouveau.txt"])
        #expect(controller.notices.isEmpty)
        #expect(await log.startedFileNames == ["lent.txt", "nouveau.txt"])
    }

    @Test("Doublon (casse ignorée) et excédent : chacun nommé dans son message, le reste est lu")
    func duplicatesAndOverflowAreNamed() async {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()), maxAttachmentCount: 2)

        controller.enqueue(["a.txt", "A.TXT", "b.txt", "c.txt"].map(pickerURL))

        #expect(controller.pendingAttachments.map(\.fileName) == ["a.txt", "b.txt"])
        #expect(controller.notices.map(\.fileNames) == [["A.TXT"], ["c.txt"]])
        #expect(controller.notices.map(\.message) == [
            FileAttachmentPresentation.alreadyAttachedMessage,
            FileAttachmentPresentation.tooManyFilesMessage(limit: 2),
        ])
        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        #expect(controller.attachments.map(\.fileName) == ["a.txt", "b.txt"])

        // Nouvelle sélection : les anciens messages, caducs, disparaissent.
        controller.enqueue([pickerURL("B.TXT")])
        #expect(controller.notices.map(\.fileNames) == [["B.TXT"]])
    }

    @Test("Échec de lecture : message fermé de l'extracteur, sous le nom du fichier")
    func extractionFailureIsShownWithClosedMessage() async {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()))

        controller.enqueue([pickerURL("scan.pdf")])

        #expect(await waitUntil { !controller.notices.isEmpty })
        #expect(controller.notices.map(\.fileNames) == [["scan.pdf"]])
        #expect(controller.notices.first?.message == AttachmentExtractionError.noExtractableText(pageCount: 3).userFacingMessage)
        #expect(controller.attachments.isEmpty)
        #expect(controller.pendingAttachments.isEmpty)
    }

    @Test("Sélecteur fermé sans choix : aucun message ; échec du sélecteur : message fixe")
    func pickerFailuresAreFilteredThenShown() {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()))

        controller.handlePickerResult(.failure(CocoaError(.userCancelled)))
        #expect(controller.notices.isEmpty)

        controller.handlePickerResult(.failure(CocoaError(.fileReadNoPermission)))
        #expect(controller.notices.map(\.message) == [FileAttachmentPresentation.pickerFailureMessage])
        #expect(controller.notices.first?.fileNames == [])
    }

    @Test("Limite de nombre atteinte, lectures en cours comprises : le bouton explique au lieu d'ouvrir")
    func explainsCountLimit() async {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()), maxAttachmentCount: 1)

        controller.enqueue([pickerURL("a.txt")])
        #expect(!controller.canAttachMore)
        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        controller.explainAttachmentLimit()

        #expect(controller.notices.map(\.message) == [FileAttachmentPresentation.countLimitReachedMessage(limit: 1)])
    }

    @Test("Budget de texte épuisé : le bouton explique la limite de texte, pas pendant une lecture")
    func explainsCharacterBudgetLimit() async {
        let controller = makeController(
            preparer: PickerFakePreparer(log: PickerTestLog(), consumedCharacters: 50),
            totalCharacterBudget: 50,
            maxCharactersPerAttachment: 50
        )

        controller.enqueue([pickerURL("a.txt")])
        #expect(controller.canAttachMore)
        #expect(await waitUntil { controller.pendingAttachments.isEmpty })
        #expect(controller.isCharacterBudgetExhausted)
        #expect(!controller.canAttachMore)
        controller.explainAttachmentLimit()

        #expect(controller.notices.map(\.message) == [AttachmentStoreError.characterBudgetExhausted.userFacingMessage])
    }

    @Test("Retrait fait directement dans le store : la capsule disparaît, aucune copie gardée")
    func attachmentsAreReadThroughTheStore() async throws {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()))
        controller.enqueue([pickerURL("a.txt")])
        #expect(await waitUntil { !controller.attachments.isEmpty })
        let attachment = try #require(controller.attachments.first)

        controller.store.remove(id: attachment.id)

        #expect(controller.attachments.isEmpty)
        #expect(controller.isEmpty)
    }

    @Test("Masquer un message ne retire que lui ; dismissAllNotices vide tout")
    func dismissingNotices() throws {
        let controller = makeController(preparer: PickerFakePreparer(log: PickerTestLog()), maxAttachmentCount: 1)
        controller.enqueue(["a.txt", "A.txt", "b.txt"].map(pickerURL))
        let duplicateNotice = try #require(controller.notices.first)

        controller.dismissNotice(id: duplicateNotice.id)
        #expect(controller.notices.map(\.fileNames) == [["b.txt"]])

        controller.dismissAllNotices()
        #expect(controller.notices.isEmpty)
    }
}
