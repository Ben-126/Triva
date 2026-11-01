//
//  ScrapeServiceDecodingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Charset et entités HTML des pages scrapées : ce que le LLM lit dépend
/// entièrement de ce décodage. Une page mal décodée met « Ã©cole » ou des
/// caractères de contrôle dans le contexte, puis dans la réponse citée.
///
/// Pas de `@MainActor` : tout ce qui est testé ici est `nonisolated` et
/// synchrone (fonctions pures de `ScrapeService`), aucun état partagé.
@Suite("ScrapeService — décodage du texte")
struct ScrapeServiceDecodingTests {
    /// ISO-8859-15 (Latin-9) : œ = 0xBD et € = 0xA4, là où windows-1252 lit
    /// « ½ » et « ¤ ». C'est ce qui rend les tests de charset DÉCLARÉ
    /// discriminants : sans lecture du charset, la détection automatique
    /// choisirait windows-1252 et le test échouerait.
    private static let isoLatin9 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin9.rawValue))
    )
    private static let latin9Sentence = "L'œuvre coûte 5 €"

    private static func latin9Bytes(_ text: String) throws -> [UInt8] {
        Array(try #require(text.data(using: isoLatin9)))
    }

    // MARK: - Charset

    /// AVANT le correctif : UTF-8 strict puis repli ISO Latin-1 pour TOUTE la
    /// page au premier octet invalide → « Ã‰lÃ¨ve Ã  l'Ã©cole ».
    @Test(
        "Page UTF-8 avec UN octet parasite : « � » à sa place, tous les autres accents intacts (charset déclaré ou non)",
        arguments: ["utf-8", "UTF-8", nil] as [String?]
    )
    func utf8PageWithStrayByteKeepsOtherAccents(declaredCharset: String?) {
        let bytes = Array("<p>Élève à l'école, déjà prête".utf8) + [0xFF] + Array(" pour Noël.</p>".utf8)

        let decoded = ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: declaredCharset)

        #expect(decoded == "<p>Élève à l'école, déjà prête\u{FFFD} pour Noël.</p>")
    }

    /// iso-8859-1 et us-ascii déclarés sont lus en windows-1252, comme le
    /// font les navigateurs (standard WHATWG) : les pages qui les déclarent
    /// contiennent en pratique des octets 0x80–0x9F (’ œ €).
    @Test(
        "Charset windows-1252 déclaré (ou iso-8859-1 / us-ascii, lus en windows-1252) : ’ œ € corrects, pas de caractères de contrôle",
        arguments: ["windows-1252", "iso-8859-1", "ISO-8859-1", "x-cp1252", "us-ascii"]
    )
    func declaredWindows1252DecodesSmartQuotesOeAndEuro(declaredCharset: String) throws {
        let text = "L’année, l’œuvre coûte 5 €"
        let bytes = Array(try #require(text.data(using: .windowsCP1252)))
        // Prémisse : les trois caractères tombent bien dans la plage 0x80–0x9F.
        #expect(bytes.contains(0x92) && bytes.contains(0x9C) && bytes.contains(0x80))

        #expect(ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: declaredCharset) == text)
    }

    @Test(
        "Sans charset HTTP : <meta charset> ou <meta http-equiv> des premiers octets respecté",
        arguments: [
            "<meta charset=\"iso-8859-15\">",
            "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-15\">",
            "<META CHARSET=ISO-8859-15>",
        ]
    )
    func metaCharsetIsHonouredWithoutHTTPCharset(metaTag: String) throws {
        let bytes = Array("<html><head>\(metaTag)</head><body><p>".utf8)
            + (try Self.latin9Bytes(Self.latin9Sentence))
            + Array("</p></body></html>".utf8)

        let decoded = ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: nil)

        #expect(decoded.contains(Self.latin9Sentence))
    }

    @Test("Priorité des navigateurs : BOM UTF-8 > charset HTTP > <meta charset>")
    func encodingPriorityFollowsBrowsers() throws {
        let metaSaysUTF8 = Array("<meta charset=\"utf-8\"><p>".utf8) + (try Self.latin9Bytes(Self.latin9Sentence)) + Array("</p>".utf8)
        let httpWinsOverMeta = ScrapeService.decodeHTML(metaSaysUTF8, isTruncated: false, declaredCharset: "iso-8859-15")
        #expect(httpWinsOverMeta.contains(Self.latin9Sentence))

        let withByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("<p>Noël</p>".utf8)
        let bomWinsOverHTTP = ScrapeService.decodeHTML(withByteOrderMark, isTruncated: false, declaredCharset: "windows-1252")
        #expect(bomWinsOverHTTP == "<p>Noël</p>")
    }

    /// Le plafond d'octets coupe n'importe où, y compris au milieu d'un
    /// caractère multi-octets : ce caractère-là doit disparaître proprement,
    /// sans « Ã » (ancien repli Latin-1) ni « � » final.
    @Test(
        "Lecture coupée au milieu d'un caractère UTF-8 (é = 0xC3 0xA9, coupé après 0xC3) : caractère incomplet retiré",
        arguments: ["utf-8", nil] as [String?]
    )
    func truncatedMultiByteSequenceIsDroppedCleanly(declaredCharset: String?) {
        let bytes = Array("Texte avant caf".utf8) + [0xC3]

        let decoded = ScrapeService.decodeHTML(bytes, isTruncated: true, declaredCharset: declaredCharset)

        #expect(decoded == "Texte avant caf")
        #expect(!decoded.contains("Ã"))
    }

    @Test("Page non tronquée, non UTF-8, sans charset déclaré : détectée windows-1252 (« Café », pas « Caf� »)")
    func undeclaredLegacyPageIsDetectedAsWindows1252() {
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9]

        #expect(ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: nil) == "Café")
    }

    @Test("Octet invalide loin de la fin d'une lecture coupée : pas pris pour une troncature, page détectée windows-1252")
    func invalidByteFarFromTheEndIsNotMistakenForTruncation() {
        let bytes: [UInt8] = [0xE9] + Array("caf, suivi d'un texte ASCII largement plus long que trois octets".utf8)

        let decoded = ScrapeService.decodeHTML(bytes, isTruncated: true, declaredCharset: nil)

        #expect(decoded.hasPrefix("é"))
    }

    @Test("Octet indéfini en windows-1252 (0x81) dans une page déclarée windows-1252 : repli ISO Latin-1, texte conservé")
    func undefinedWindows1252ByteFallsBackToLatin1() {
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9, 0x81] + Array(" ouvert".utf8)

        #expect(ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: "windows-1252") == "Café\u{81} ouvert")
    }

    @Test("Charset inconnu (« bogus ») : ignoré, repli sur la détection")
    func unknownCharsetFallsBackToDetection() {
        #expect(ScrapeService.encoding(forCharsetLabel: "bogus-charset") == nil)
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9]
        #expect(ScrapeService.decodeHTML(bytes, isTruncated: false, declaredCharset: "bogus-charset") == "Café")
    }

    // MARK: - Entités HTML

    /// AVANT le correctif : 14 entités seulement — `&eacute;`, `&laquo;`,
    /// `&euro;`… restaient telles quelles dans le contexte, titres compris.
    @Test(
        "Entités nommées courantes en français décodées (accents, guillemets, €, tirets, œ, espace insécable…)",
        arguments: [
            ("&eacute;", "é"), ("&Eacute;", "É"), ("&egrave;", "è"), ("&agrave;", "à"), ("&ccedil;", "ç"), ("&ecirc;", "ê"),
            ("&ocirc;", "ô"), ("&ucirc;", "û"), ("&iuml;", "ï"), ("&yuml;", "ÿ"), ("&oelig;", "œ"), ("&OElig;", "Œ"),
            ("&laquo;", "«"), ("&raquo;", "»"), ("&euro;", "€"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&ndash;", "–"), ("&mdash;", "—"), ("&nbsp;", "\u{A0}"), ("&deg;", "°"),
            ("&copy;", "©"), ("&szlig;", "ß"), ("&amp;", "&"), ("&apos;", "'"),
        ]
    )
    func namedEntityIsDecoded(entity: String, expected: String) {
        #expect(ScrapeService.decodeHTMLEntities("a\(entity)b") == "a\(expected)b")
    }

    @Test("`&eacute;&laquo;&euro;` décodés d'un bloc")
    func frenchEntitySequenceIsDecoded() {
        #expect(ScrapeService.decodeHTMLEntities("&eacute;&laquo;&euro;") == "é«€")
    }

    /// AVANT le correctif : remplacements successifs, `&amp;` EN PREMIER —
    /// `&amp;lt;` devenait `&lt;` puis `<` (décodé deux fois).
    @Test(
        "`&amp;` décodé en UNE passe : `&amp;lt;` → `&lt;`, jamais `<`",
        arguments: [("&amp;lt;", "&lt;"), ("&amp;amp;", "&amp;"), ("&amp;#233;", "&#233;"), ("Tom &amp; Jerry", "Tom & Jerry")]
    )
    func ampersandIsDecodedOnlyOnce(input: String, expected: String) {
        #expect(ScrapeService.decodeHTMLEntities(input) == expected)
    }

    @Test(
        "Références numériques : 128–159 lues en windows-1252 comme les navigateurs (&#146; = ’, &#128; = €)",
        arguments: [("&#146;", "’"), ("&#x92;", "’"), ("&#128;", "€"), ("&#156;", "œ"), ("&#233;", "é"), ("&#x1F600;", "😀")]
    )
    func numericReferenceIsDecoded(input: String, expected: String) {
        #expect(ScrapeService.decodeHTMLEntities(input) == expected)
    }

    @Test(
        "Entité inconnue, point de code invalide ou esperluette nue : laissés tels quels",
        arguments: ["&inconnue;", "&#0;", "&#xD800;", "&#1114112;", "AT&T", "a & b", "&;", "&#;", "&#x;"]
    )
    func unknownOrInvalidEntityIsLeftUntouched(input: String) {
        #expect(ScrapeService.decodeHTMLEntities(input) == input)
    }

    @Test("Titre avec entités (Caf&eacute; &laquo;&nbsp;Le Flore&nbsp;&raquo;) : décodé et blancs normalisés")
    func titleEntitiesAreDecoded() {
        let html = "<html><head><title>Caf&eacute; &laquo;&nbsp;Le Flore&nbsp;&raquo;</title></head><body></body></html>"

        let (title, _) = ScrapeService.extractMainContent(fromHTML: html)

        #expect(title == "Café « Le Flore »")
    }
}
