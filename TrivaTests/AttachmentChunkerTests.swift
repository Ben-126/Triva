//
//  AttachmentChunkerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 29/09/2026.
//
//  Contient aussi les suites de la recherche (`AttachmentSearchIndex`) et du
//  store (`AttachmentStore`) : le périmètre de la tâche 1.11a ne prévoit pas
//  de fichier de tests dédié, et la recherche opère sur les fragments.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Aides communes

/// Texte long, réaliste et SANS répétition (chaque phrase porte un numéro) :
/// une répétition permettrait à un recouvrement de « coïncider » plus loin
/// qu'il ne va vraiment, et fausserait les tests de recouvrement.
private func makeUniqueText(paragraphs: Int, sentencesPerParagraph: Int = 4) -> String {
    (0..<paragraphs).map { paragraph in
        (0..<sentencesPerParagraph).map { sentence in
            "La phrase \(paragraph * sentencesPerParagraph + sentence) décrit une étape précise du processus étudié."
        }.joined(separator: " ")
    }.joined(separator: "\n\n")
}

/// Texte sans aucun blanc : vérifie que rien n'est perdu ni dupliqué, quels
/// que soient les blancs retirés aux bords des fragments.
private func visibleCharacters(_ text: String) -> String {
    String(text.filter { !$0.isWhitespace })
}

/// Longueur du plus long suffixe de `previous` qui ouvre `next` (0 si aucun).
private func sharedOverlapLength(previous: String, next: String) -> Int {
    let limit = min(previous.count, next.count)
    guard limit > 0 else { return 0 }
    return (1...limit).reversed().first { next.hasPrefix(String(previous.suffix($0))) } ?? 0
}

// MARK: - Découpage

@Suite("Découpage — cas limites")
struct AttachmentChunkerEdgeCaseTests {
    @Test("Texte vide ou blanc : aucun fragment")
    func emptyInput() {
        #expect(AttachmentChunker().chunks(for: "").isEmpty)
        #expect(AttachmentChunker().chunks(for: "  \n\n\t \r\n ").isEmpty)
    }

    @Test("Texte plus court qu'un fragment : un seul fragment, blancs de bord retirés")
    func shortText() {
        let chunks = AttachmentChunker().chunks(for: "  Une seule phrase courte.  ")

        #expect(chunks == [AttachmentChunk(index: 0, text: "Une seule phrase courte.", pageRange: nil)])
    }

    @Test("Texte d'exactement la taille maximale : un seul fragment, même avec recouvrement configuré")
    func exactlyMaximumLength() {
        let text = "abcdefghijklmnopqrst"

        let chunks = AttachmentChunker(maxCharacters: 20, overlapCharacters: 5).chunks(for: text)

        #expect(chunks.map(\.text) == [text])
    }

    @Test("Paramètres ramenés dans un domaine sûr", arguments: zip(
        [(0, 5), (100, 90), (100, -3), (-10, -10), (800, 150)],
        [(1, 0), (100, 50), (100, 0), (1, 0), (800, 150)]
    ))
    func parametersAreClamped(requested: (Int, Int), expected: (Int, Int)) {
        let chunker = AttachmentChunker(maxCharacters: requested.0, overlapCharacters: requested.1)

        #expect(chunker.maxCharacters == expected.0)
        #expect(chunker.overlapCharacters == expected.1)
    }
}

@Suite("Découpage — invariants")
struct AttachmentChunkerInvariantTests {
    @Test("Taille jamais dépassée (recouvrement compris), fragments non vides, indices consécutifs", arguments: zip(
        [800, 200, 120, 60, 25],
        [150, 40, 0, 30, 12]
    ))
    func sizeAndIndexInvariants(maxCharacters: Int, overlapCharacters: Int) {
        let chunker = AttachmentChunker(maxCharacters: maxCharacters, overlapCharacters: overlapCharacters)

        let chunks = chunker.chunks(for: makeUniqueText(paragraphs: 12))

        #expect(chunks.count > 1)
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
        for chunk in chunks {
            #expect(chunk.text.count <= maxCharacters)
            #expect(!chunk.text.isEmpty)
            #expect(chunk.text == chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test("Sans recouvrement, rien n'est perdu ni dupliqué", arguments: [40, 120, 400])
    func lossless(maxCharacters: Int) {
        let text = makeUniqueText(paragraphs: 8)

        let chunks = AttachmentChunker(maxCharacters: maxCharacters, overlapCharacters: 0).chunks(for: text)

        #expect(visibleCharacters(chunks.map(\.text).joined()) == visibleCharacters(text))
    }

    @Test("Un document bien au-delà de la borne par fichier (12 500 caractères) se découpe sans explosion de coût", .timeLimit(.minutes(1)))
    func defaultBudgetDocument() {
        // ~243 caractères par paragraphe de 4 phrases : 430 paragraphes ≈ 104 000.
        let text = makeUniqueText(paragraphs: 430)
        #expect(text.count >= 100_000)

        let chunks = AttachmentChunker().chunks(for: text)

        #expect(chunks.allSatisfy { $0.text.count <= AttachmentChunker.defaultMaxCharacters })
        #expect(chunks.count > 100)
    }
}

@Suite("Découpage — frontières naturelles")
struct AttachmentChunkerBoundaryTests {
    @Test("Coupe entre deux phrases, jamais au milieu d'une phrase qui tient")
    func cutsBetweenSentences() {
        let text = "Première phrase de test. Deuxième phrase de test. Troisième phrase de test."

        let chunks = AttachmentChunker(maxCharacters: 55, overlapCharacters: 0).chunks(for: text)

        #expect(chunks.map(\.text) == ["Première phrase de test. Deuxième phrase de test.", "Troisième phrase de test."])
    }

    @Test("Un paragraphe qui tient n'est jamais coupé")
    func keepsParagraphsWhole() {
        let paragraphs = [
            "Le premier paragraphe parle du climat.",
            "Le deuxième paragraphe parle des sols.",
            "Le troisième évoque les forêts humides.",
        ]

        let chunks = AttachmentChunker(maxCharacters: 60, overlapCharacters: 0).chunks(for: paragraphs.joined(separator: "\n\n"))

        #expect(chunks.map(\.text) == paragraphs)
    }

    @Test("Jamais de mot coupé, recouvrement compris, même sans aucune ponctuation")
    func neverSplitsWords() {
        let vocabulary = ["soleil", "rivière", "montagne", "forêt", "océan", "prairie", "nuage", "désert"]
        let text = (0..<320).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")

        let chunks = AttachmentChunker(maxCharacters: 50, overlapCharacters: 12).chunks(for: text)

        #expect(chunks.count > 10)
        for chunk in chunks {
            let words = chunk.text.split(whereSeparator: \.isWhitespace).map(String.init)
            #expect(Set(words).isSubset(of: Set(vocabulary)))
        }
    }

    @Test("Le recouvrement reprend la fin du fragment précédent, à partir d'une frontière de mot")
    func overlapIsSuffixOfPreviousChunk() {
        let chunks = AttachmentChunker(maxCharacters: 200, overlapCharacters: 60).chunks(for: makeUniqueText(paragraphs: 6))

        #expect(chunks.count > 2)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let length = sharedOverlapLength(previous: previous.text, next: next.text)
            #expect(length > 0)
            #expect(length <= 60)

            let overlapStart = previous.text.index(previous.text.endIndex, offsetBy: -length)
            let startsOnWord = overlapStart == previous.text.startIndex
                || previous.text[previous.text.index(before: overlapStart)].isWhitespace
            #expect(startsOnWord)
        }
    }

    @Test("Le recouvrement démarre sur un début de phrase dès qu'une phrase tient dans la fenêtre")
    func overlapPrefersSentenceStart() {
        let text = (0..<30).map { "Phrase numéro \($0) du test." }.joined(separator: " ")

        let chunks = AttachmentChunker(maxCharacters: 120, overlapCharacters: 50).chunks(for: text)

        #expect(chunks.count > 2)
        #expect(chunks.dropFirst().allSatisfy { $0.text.hasPrefix("Phrase numéro") })
    }

    @Test("Un « mot » plus long qu'un fragment est coupé franchement, sans rien perdre")
    func giantTokenIsHardSplit() {
        let token = "https://exemple.fr/" + String(repeating: "a", count: 280)

        let chunks = AttachmentChunker(maxCharacters: 100, overlapCharacters: 0).chunks(for: token)

        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.text.count <= 100 })
        #expect(chunks.map(\.text).joined() == token)
    }

    @Test("Ligne vide Windows (\\r\\n\\r\\n) reconnue comme séparateur de paragraphes")
    func windowsBlankLineSeparatesParagraphs() {
        let chunks = AttachmentChunker(maxCharacters: 15, overlapCharacters: 0).chunks(for: "Premier bloc.\r\n\r\nSecond bloc.")

        #expect(chunks.map(\.text) == ["Premier bloc.", "Second bloc."])
    }
}

@Suite("Découpage — sûreté Unicode")
struct AttachmentChunkerUnicodeTests {
    /// Tout caractère d'un fragment doit exister tel quel dans l'original : un
    /// emoji famille coupé donnerait « 👨‍👩‍ », un drapeau coupé un indicateur
    /// régional isolé, un accent décomposé coupé un « ́ » orphelin — aucun de
    /// ces morceaux n'est un `Character` du texte d'origine.
    private func expectWholeGraphemes(_ chunks: [AttachmentChunk], from original: String, maxCharacters: Int) {
        let originalCharacters = Set(original)
        for chunk in chunks {
            #expect(chunk.text.count <= maxCharacters)
            #expect(Set(chunk.text).isSubset(of: originalCharacters))
        }
    }

    @Test("Emoji composés, accents décomposés, drapeaux, CJK : aucun graphème coupé", arguments: [1, 2, 3, 5, 8, 13])
    func mixedUnicode(maxCharacters: Int) {
        let text = String(repeating: "Café 👨‍👩‍👧‍👦 e\u{301}te\u{301} 🇫🇷🇨🇦 東京 👍🏽 fin. ", count: 5)

        let chunks = AttachmentChunker(maxCharacters: maxCharacters, overlapCharacters: 0).chunks(for: text)

        expectWholeGraphemes(chunks, from: text, maxCharacters: maxCharacters)
        #expect(visibleCharacters(chunks.map(\.text).joined()) == visibleCharacters(text))
    }

    @Test("Drapeaux collés sans espace : jamais d'indicateur régional isolé, recouvrement compris")
    func flagsWithoutSpaces() {
        let text = String(repeating: "🇫🇷🇨🇦🇯🇵🇧🇷", count: 10)

        let chunks = AttachmentChunker(maxCharacters: 3, overlapCharacters: 1).chunks(for: text)

        expectWholeGraphemes(chunks, from: text, maxCharacters: 3)
    }

    @Test("Accents décomposés collés : aucun fragment ne commence par un accent combinant orphelin")
    func decomposedAccents() {
        let text = String(repeating: "e\u{301}", count: 50)

        let chunks = AttachmentChunker(maxCharacters: 4, overlapCharacters: 0).chunks(for: text)

        expectWholeGraphemes(chunks, from: text, maxCharacters: 4)
        #expect(chunks.allSatisfy { $0.text.unicodeScalars.first?.value != 0x301 })
    }

    @Test("Écriture sans espaces (japonais) : fragments bornés, rien de perdu")
    func japaneseWithoutSpaces() {
        let text = String(repeating: "東京は日本の首都です。大阪は食べ物で有名です。", count: 6)

        let withOverlap = AttachmentChunker(maxCharacters: 10, overlapCharacters: 3).chunks(for: text)
        let withoutOverlap = AttachmentChunker(maxCharacters: 10, overlapCharacters: 0).chunks(for: text)

        expectWholeGraphemes(withOverlap, from: text, maxCharacters: 10)
        #expect(withoutOverlap.map(\.text).joined() == text)
    }
}

@Suite("Découpage — pagination")
struct AttachmentChunkerPaginationTests {
    @Test("Deux pages dans un même fragment : plage de pages 1–2")
    func chunkSpanningPages() {
        let sections = [
            ExtractedTextSection(pageNumber: 1, text: "Texte de la page un."),
            ExtractedTextSection(pageNumber: 2, text: "Texte de la page deux."),
        ]

        let chunks = AttachmentChunker().chunks(for: sections)

        #expect(chunks == [AttachmentChunk(index: 0, text: "Texte de la page un.\n\nTexte de la page deux.", pageRange: 1...2)])
    }

    @Test("Un fragment par page quand elles ne tiennent pas ensemble")
    func oneChunkPerPage() {
        let sections = [
            ExtractedTextSection(pageNumber: 1, text: "Texte de la page un."),
            ExtractedTextSection(pageNumber: 2, text: "Texte de la page deux."),
        ]

        let chunks = AttachmentChunker(maxCharacters: 25, overlapCharacters: 0).chunks(for: sections)

        #expect(chunks.map(\.text) == ["Texte de la page un.", "Texte de la page deux."])
        #expect(chunks.map(\.pageRange) == [1...1, 2...2])
    }

    @Test("Section blanche écartée, la plage de pages reste celle du texte réel")
    func blankSectionSkipped() {
        let sections = [
            ExtractedTextSection(pageNumber: 1, text: "Alpha."),
            ExtractedTextSection(pageNumber: 2, text: "   \n "),
            ExtractedTextSection(pageNumber: 3, text: "Gamma."),
        ]

        let chunks = AttachmentChunker().chunks(for: sections)

        #expect(chunks == [AttachmentChunk(index: 0, text: "Alpha.\n\nGamma.", pageRange: 1...3)])
    }
}

// MARK: - Recherche

/// Pièce jointe construite à la main : les tests de recherche ne dépendent
/// ainsi ni du découpage ni de l'extraction.
private func makeAttachment(
    _ fileName: String,
    chunks texts: [String],
    pages: [ClosedRange<Int>?]? = nil,
    id: UUID = UUID()
) -> IndexedAttachment {
    let chunks = texts.enumerated().map { position, text in
        AttachmentChunk(index: position, text: text, pageRange: pages?[position])
    }
    return IndexedAttachment(
        id: id,
        fileName: fileName,
        kind: pages == nil ? .plainText : .pdf,
        pageCount: nil,
        characterCount: texts.reduce(0) { $0 + $1.count },
        isTruncated: false,
        isCopyRestricted: false,
        chunks: chunks
    )
}

/// Journal des requêtes reçues par un scorer factice.
private actor ScorerCallLog {
    private(set) var references: [String] = []

    func record(_ reference: String) {
        references.append(reference)
    }
}

/// Scorer factice DÉTERMINISTE : score fixé par couple (requête, fragment),
/// 0 pour tout couple absent de la table. Jamais de vrai modèle ici — le
/// classement doit être entièrement prévisible.
private struct TableScorer: TextSimilarityScoring {
    let table: [String: [String: Double]]
    let log: ScorerCallLog

    init(_ table: [String: [String: Double]], log: ScorerCallLog = ScorerCallLog()) {
        self.table = table
        self.log = log
    }

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        await log.record(reference)
        return candidates.map { table[reference]?[$0] ?? 0 }
    }
}

/// Viole le contrat du protocole : un seul score, quel que soit le lot.
private struct ShortScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        [0.9]
    }
}

/// Viole le contrat du protocole : un score non fini.
private struct NaNScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        candidates.indices.map { $0 == 0 ? Double.nan : 0.5 }
    }
}

@Suite("Recherche dans les fragments")
struct AttachmentSearchIndexTests {
    @Test("Les N meilleurs fragments, par score décroissant, avec leur provenance")
    func topMatchesWithProvenance() async {
        let report = makeAttachment("rapport.pdf", chunks: ["alpha", "beta", "gamma"], pages: [1...1, 2...3, 4...4])
        let notes = makeAttachment("notes.txt", chunks: ["delta"])
        let scorer = TableScorer(["q": ["alpha": 0.2, "beta": 0.9, "gamma": 0.5, "delta": 0.7]])

        let matches = await AttachmentSearchIndex(attachments: [report, notes], scorer: scorer).search(query: "q", limit: 3)

        #expect(matches == [
            AttachmentSearchMatch(attachmentID: report.id, fileName: "rapport.pdf", chunkIndex: 1, pageRange: 2...3, text: "beta", score: 0.9),
            AttachmentSearchMatch(attachmentID: notes.id, fileName: "notes.txt", chunkIndex: 0, pageRange: nil, text: "delta", score: 0.7),
            AttachmentSearchMatch(attachmentID: report.id, fileName: "rapport.pdf", chunkIndex: 2, pageRange: 4...4, text: "gamma", score: 0.5),
        ])
    }

    @Test("Limite nulle, requête blanche ou aucun fragment : rien, et le scorer n'est jamais appelé")
    func degenerateInputsSkipScorer() async {
        let log = ScorerCallLog()
        let scorer = TableScorer([:], log: log)
        let populated = AttachmentSearchIndex(attachments: [makeAttachment("a.txt", chunks: ["texte"])], scorer: scorer)

        #expect(await populated.search(query: "q", limit: 0).isEmpty)
        #expect(await populated.search(query: "  \n ", limit: 5).isEmpty)
        #expect(await AttachmentSearchIndex(attachments: [], scorer: scorer).search(query: "q", limit: 5).isEmpty)
        #expect(await AttachmentSearchIndex(attachments: [makeAttachment("b.txt", chunks: [])], scorer: scorer).search(query: "q", limit: 5).isEmpty)
        #expect(await populated.search(queries: ["", "   "], limit: 5).isEmpty)
        #expect(await log.references.isEmpty)
    }

    @Test("À score égal, l'ordre des pièces jointes puis des fragments est conservé")
    func tiesKeepOriginalOrder() async {
        let first = makeAttachment("a.txt", chunks: ["un", "deux"])
        let second = makeAttachment("b.txt", chunks: ["trois"])
        let scorer = TableScorer(["q": ["un": 0.5, "deux": 0.5, "trois": 0.5]])

        let matches = await AttachmentSearchIndex(attachments: [first, second], scorer: scorer).search(query: "q", limit: 10)

        #expect(matches.map(\.text) == ["un", "deux", "trois"])
    }

    @Test("Aucun seuil : un fragment à 0 reste classé s'il n'y a pas mieux (limite de langue mesurée)")
    func noAbsoluteThreshold() async {
        let attachment = makeAttachment("a.txt", chunks: ["premier", "second"])

        let matches = await AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:])).search(query: "q", limit: 10)

        #expect(matches.map(\.text) == ["premier", "second"])
        #expect(matches.map(\.score) == [0, 0])
    }

    @Test("Scorer hors contrat (trop peu de scores, NaN) : repli à 0, jamais de plantage ni de fragment perdu")
    func contractViolationsFallBackToZero() async {
        let attachment = makeAttachment("a.txt", chunks: ["un", "deux", "trois"])

        let short = await AttachmentSearchIndex(attachments: [attachment], scorer: ShortScorer()).search(query: "q", limit: 10)
        let notANumber = await AttachmentSearchIndex(attachments: [attachment], scorer: NaNScorer()).search(query: "q", limit: 10)

        #expect(short.map(\.text) == ["un", "deux", "trois"])
        #expect(short.map(\.score) == [0.9, 0, 0])
        #expect(notANumber.map(\.text) == ["deux", "trois", "un"])
        #expect(notANumber.last?.score == 0)
    }

    @Test("Plusieurs requêtes : fusion par rangs, un fragment bien classé partout l'emporte")
    func multiQueryFusion() async {
        let attachment = makeAttachment("a.txt", chunks: ["A", "B", "C"])
        let scorer = TableScorer([
            "q1": ["A": 0.9, "B": 0.8, "C": 0.1],
            "q2": ["A": 0.1, "B": 0.8, "C": 0.9],
        ])

        let matches = await AttachmentSearchIndex(attachments: [attachment], scorer: scorer).search(queries: ["q1", "q2"], limit: 3)

        // B : 0,8/62 × 2 ; A et C : 0,9/61 + 0,1/63 → égalité, départagée par l'ordre.
        #expect(matches.map(\.text) == ["B", "A", "C"])
        #expect(matches.first?.score == 0.8 / 62 + 0.8 / 62)
        #expect(matches[1].score == matches[2].score)
    }

    @Test("Requêtes en double ou blanches retirées : un passage du scorer par requête distincte")
    func duplicateQueriesAreScoredOnce() async {
        let log = ScorerCallLog()
        let index = AttachmentSearchIndex(attachments: [makeAttachment("a.txt", chunks: ["texte"])], scorer: TableScorer([:], log: log))

        _ = await index.search(queries: ["q1", "q1", "  ", "q2"], limit: 5)

        #expect(await log.references == ["q1", "q2"])
    }
}

@Suite("Pièces jointes indexées — présentation")
struct IndexedAttachmentPresentationTests {
    @Test("Contenu initial : les trois premiers fragments, séparés comme dans la version web d'origine")
    func initialContent() {
        let attachment = makeAttachment("a.txt", chunks: ["un", "deux", "trois", "quatre"])

        #expect(attachment.initialContent() == "un\n---\ndeux\n---\ntrois")
        #expect(attachment.initialContent(maxChunks: 0).isEmpty)
        #expect(attachment.initialContent(maxChunks: 10) == "un\n---\ndeux\n---\ntrois\n---\nquatre")
    }

    @Test("Provenance lisible : page seule, plage de pages, ou nom de fichier seul")
    func provenanceLabel() {
        func match(_ fileName: String, _ pages: ClosedRange<Int>?) -> AttachmentSearchMatch {
            AttachmentSearchMatch(attachmentID: UUID(), fileName: fileName, chunkIndex: 0, pageRange: pages, text: "", score: 0)
        }

        #expect(match("rapport.pdf", 3...3).provenanceLabel == "rapport.pdf, p. 3")
        #expect(match("rapport.pdf", 3...4).provenanceLabel == "rapport.pdf, p. 3–4")
        #expect(match("notes.txt", nil).provenanceLabel == "notes.txt")
    }
}

// MARK: - Store

/// Porte de synchronisation : retient une préparation « en cours » jusqu'à
/// ce que le test l'ouvre, pour observer le store PENDANT une lecture.
private actor PreparationGate {
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

/// Limites de caractères reçues par le préparateur factice, dans l'ordre.
private actor PreparationLog {
    private(set) var limits: [Int] = []

    func record(_ limit: Int) {
        limits.append(limit)
    }
}

/// Préparateur factice : ni disque ni PDF. Consomme toute la limite reçue
/// (ou `consumedCharacters` si plus petit), éventuellement après une porte.
private struct FakePreparer: AttachmentPreparing {
    let log: PreparationLog
    var gate: PreparationGate?
    var consumedCharacters: Int?

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        await log.record(characterLimit)
        if let gate {
            await gate.wait()
        }
        return IndexedAttachment(
            fileName: url.lastPathComponent,
            kind: .plainText,
            pageCount: nil,
            characterCount: min(consumedCharacters ?? characterLimit, characterLimit),
            isTruncated: false,
            isCopyRestricted: false,
            chunks: [AttachmentChunk(index: 0, text: "Contenu de \(url.lastPathComponent)", pageRange: nil)]
        )
    }
}

/// Attente coopérative bornée. `Task.sleep` et JAMAIS `Task.yield()` : avec
/// l'isolation MainActor, `yield()` ne garantit pas que l'autre tâche
/// progresse (piège documenté dans `ChatViewModelTests`).
private func pollUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func fakeURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: "/fichiers-factices").appendingPathComponent(fileName)
}

@MainActor
@Suite("Magasin de pièces jointes")
struct AttachmentStoreTests {
    @Test("Chaîne réelle : fichier texte lu, découpé, puis retrouvé par la recherche")
    func realPipeline() async throws {
        let text = "Paris est la capitale de la France. Lyon est connue pour sa gastronomie."
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.txt")
        try Data(text.utf8).write(to: url)
        let store = AttachmentStore(scorer: TableScorer(["capitale": [text: 0.8]]))

        let attachment = try await store.attach(fileAt: url)
        let matches = await store.search(query: "capitale", limit: 5)

        #expect(store.attachments == [attachment])
        #expect(attachment.kind == .plainText)
        #expect(attachment.characterCount == text.count)
        #expect(matches.map(\.provenanceLabel) == ["notes.txt"])
        #expect(matches.first?.score == 0.8)
        #expect(store.remainingCharacterBudget == store.totalCharacterBudget - text.count)
    }

    @Test("Type refusé : erreur relayée, rien d'ajouté, budget intact")
    func unsupportedFileLeavesStoreUntouched() async {
        let store = AttachmentStore(scorer: TableScorer([:]))

        await #expect(throws: AttachmentExtractionError.unsupportedFileType(fileExtension: "png")) {
            try await store.attach(fileAt: fakeURL("photo.png"))
        }
        #expect(store.attachments.isEmpty)
        #expect(store.remainingCharacterBudget == store.totalCharacterBudget)
    }

    @Test("Budget partagé : chaque lecture reçoit le reste, puis l'ajout est refusé à budget nul")
    func budgetIsSharedThenExhausted() async throws {
        let log = PreparationLog()
        let store = AttachmentStore(
            scorer: TableScorer([:]),
            preparer: FakePreparer(log: log),
            totalCharacterBudget: 100,
            maxCharactersPerAttachment: 60
        )

        try await store.attach(fileAt: fakeURL("a.txt"))
        try await store.attach(fileAt: fakeURL("b.txt"))

        await #expect(throws: AttachmentStoreError.characterBudgetExhausted) {
            try await store.attach(fileAt: fakeURL("c.txt"))
        }
        #expect(await log.limits == [60, 40])
        #expect(store.indexedCharacterCount == 100)
        #expect(store.attachments.count == 2)
    }

    @Test("Deux lectures simultanées : la seconde ne voit que le budget non réservé par la première")
    func concurrentReadsReserveBudget() async throws {
        let log = PreparationLog()
        let gate = PreparationGate()
        let store = AttachmentStore(
            scorer: TableScorer([:]),
            preparer: FakePreparer(log: log, gate: gate),
            totalCharacterBudget: 100,
            maxCharactersPerAttachment: 60
        )

        let first = Task { try await store.attach(fileAt: fakeURL("a.txt")) }
        #expect(await pollUntil { await log.limits.count == 1 })
        #expect(store.remainingCharacterBudget == 40)
        let second = Task { try await store.attach(fileAt: fakeURL("b.txt")) }
        #expect(await pollUntil { await log.limits.count == 2 })
        await gate.open()
        _ = try await first.value
        _ = try await second.value

        #expect(await log.limits == [60, 40])
        #expect(store.indexedCharacterCount == 100)
        #expect(store.remainingCharacterBudget == 0)
    }

    @Test("Vidage pendant une lecture : la lecture est abandonnée, rien ne réapparaît")
    func removeAllDuringReadDiscardsResult() async {
        let log = PreparationLog()
        let gate = PreparationGate()
        let store = AttachmentStore(scorer: TableScorer([:]), preparer: FakePreparer(log: log, gate: gate))

        let pending = Task { try await store.attach(fileAt: fakeURL("a.txt")) }
        #expect(await pollUntil { await log.limits.count == 1 })
        store.removeAll()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
        #expect(store.attachments.isEmpty)
        #expect(store.remainingCharacterBudget == store.totalCharacterBudget)
    }

    @Test("Retrait d'une pièce jointe : seule elle disparaît, son budget est rendu")
    func removeFreesBudget() async throws {
        let store = AttachmentStore(
            scorer: TableScorer([:]),
            preparer: FakePreparer(log: PreparationLog(), consumedCharacters: 30),
            totalCharacterBudget: 100
        )
        let first = try await store.attach(fileAt: fakeURL("a.txt"))
        let second = try await store.attach(fileAt: fakeURL("b.txt"))

        store.remove(id: first.id)

        #expect(store.attachments == [second])
        #expect(store.remainingCharacterBudget == 70)
    }

    @Test("L'instantané de recherche ne bouge plus une fois pris")
    func searchIndexIsASnapshot() async throws {
        let store = AttachmentStore(scorer: TableScorer([:]), preparer: FakePreparer(log: PreparationLog(), consumedCharacters: 10))
        try await store.attach(fileAt: fakeURL("a.txt"))

        let snapshot = store.searchIndex
        store.removeAll()

        #expect(snapshot.attachments.count == 1)
        #expect(await snapshot.search(query: "q", limit: 5).count == 1)
    }
}
