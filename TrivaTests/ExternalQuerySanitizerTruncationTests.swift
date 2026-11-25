//
//  ExternalQuerySanitizerTruncationTests.swift
//  TrivaTests
//
//  K2 : la troncature à 2000 caractères d'un texte venu de l'extérieur n'est plus silencieuse.
//  `sanitizeReportingTruncation` dit si quelque chose a été coupé ; `sanitize` rend le même texte qu'avant.
//

import Foundation
import Testing
@testable import Triva

@Suite("Texte externe — troncature annoncée")
struct ExternalQuerySanitizerTruncationTests {
    private var limit: Int { ExternalQuerySanitizer.maxLength }

    @Test("Un texte court n'est pas signalé comme coupé")
    func shortTextIsNotTruncated() {
        let result = ExternalQuerySanitizer.sanitizeReportingTruncation("Capitale du Japon ?")
        #expect(result == SanitizedExternalText(text: "Capitale du Japon ?", wasTruncated: false))
    }

    @Test("Exactement la limite : rien n'est coupé")
    func exactlyAtLimitIsNotTruncated() throws {
        let text = String(repeating: "a", count: limit)
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(text))
        #expect(result.text.count == limit)
        #expect(!result.wasTruncated)
    }

    @Test("Un caractère de plus que la limite : coupé et signalé")
    func oneOverLimitIsTruncated() throws {
        let text = String(repeating: "a", count: limit + 1)
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(text))
        #expect(result.text.count == limit)
        #expect(result.wasTruncated)
    }

    @Test("Des espaces en fin de texte ne comptent pas : ce n'est pas une troncature")
    func trailingWhitespaceIsNotATruncation() throws {
        let text = String(repeating: "a", count: limit) + String(repeating: " ", count: 500) + "\n\n"
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(text))
        #expect(!result.wasTruncated)
    }

    @Test("Un texte gigantesque (au-delà de la borne de travail) est signalé comme coupé")
    func hugeTextIsReportedTruncated() throws {
        let text = String(repeating: "mot ", count: 60_000)
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(text))
        #expect(result.text.count <= limit)
        #expect(result.wasTruncated)
    }

    @Test("Vide ou blanc : rien, comme sanitize")
    func emptyGivesNil() {
        #expect(ExternalQuerySanitizer.sanitizeReportingTruncation("  \n ") == nil)
        #expect(ExternalQuerySanitizer.sanitizeReportingTruncation(nil) == nil)
    }

    @Test("sanitize rend exactement le texte de sanitizeReportingTruncation", arguments: [
        "Bonjour", "  espaces \t et tab  ", "ligne1\r\nligne2", String(repeating: "é", count: 2_500),
    ])
    func sanitizeIsUnchanged(text: String) {
        #expect(ExternalQuerySanitizer.sanitize(text) == ExternalQuerySanitizer.sanitizeReportingTruncation(text)?.text)
    }
}
