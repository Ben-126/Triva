//
//  UploadsSearchTestSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures

/// Journal des requêtes reçues par le scorer : prouve QUELLES requêtes (et
/// combien) atteignent réellement l'index.
actor UploadsQueryLog {
    private(set) var references: [String] = []

    func record(_ reference: String) {
        references.append(reference)
    }
}

/// Scorer factice DÉTERMINISTE : score fixé par couple (requête, fragment),
/// 0 pour tout couple absent. Jamais de vrai modèle ici — le classement doit
/// être entièrement prévisible.
struct UploadsTableScorer: TextSimilarityScoring {
    let table: [String: [String: Double]]
    let log: UploadsQueryLog

    init(_ table: [String: [String: Double]], log: UploadsQueryLog = UploadsQueryLog()) {
        self.table = table
        self.log = log
    }

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        await log.record(reference)
        return candidates.map { table[reference]?[$0] ?? 0 }
    }
}

/// Client SearXNG qui compte ses appels : l'action ne doit JAMAIS sortir sur
/// le réseau, même si on lui passe un `FailoverManager` fonctionnel.
actor UploadsCountingSearXNGClient {
    private(set) var callCount = 0
}

extension UploadsCountingSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        return SearXNGSearchResponse(results: [], suggestions: [])
    }
}

struct UploadsUnusedScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

/// Préparateur factice : rend toujours la même pièce jointe, sans disque.
struct UploadsFixedPreparer: AttachmentPreparing {
    let attachment: IndexedAttachment

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        attachment
    }
}

// MARK: - Fabriques

func uploadsMakeAttachment(_ fileName: String, chunks: [String], pages: [ClosedRange<Int>?]? = nil) -> IndexedAttachment {
    let built = chunks.enumerated().map { index, text in
        AttachmentChunk(index: index, text: text, pageRange: pages?[index])
    }
    return IndexedAttachment(
        fileName: fileName,
        kind: pages == nil ? .plainText : .pdf,
        pageCount: pages == nil ? nil : pages?.compactMap { $0?.upperBound }.max(),
        characterCount: chunks.reduce(0) { $0 + $1.count },
        isTruncated: false,
        isCopyRestricted: false,
        chunks: built
    )
}

func uploadsMakeMatch(
    _ attachmentID: UUID,
    fileName: String = "doc.txt",
    chunkIndex: Int,
    text: String,
    pageRange: ClosedRange<Int>? = nil,
    score: Double = 0.5
) -> AttachmentSearchMatch {
    AttachmentSearchMatch(
        attachmentID: attachmentID,
        fileName: fileName,
        chunkIndex: chunkIndex,
        pageRange: pageRange,
        text: text,
        score: score
    )
}

let uploadsTestInstance = URL(string: "https://searx.example")!

func uploadsResults(of output: SearchActionOutput) -> [SearXNGSearchResult]? {
    if case .searchResults(let results) = output { return results }
    return nil
}
