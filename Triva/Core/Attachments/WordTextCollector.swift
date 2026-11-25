//
//  WordTextCollector.swift
//  Triva
//
//  Mission W (lecture des .docx) : transforme les événements XML d'un document WordprocessingML en texte lisible.
//  Reconnaît les éléments par NOM LOCAL + ESPACE DE NOMS (jamais par le préfixe `w:`), en variante « transitional » comme
//  « strict ».
//
//  Ce qui est lu : le texte des passages (`w:t`), les tabulations et sauts de ligne D'UN PASSAGE (`w:r`) — les arrêts
//  de tabulation d'un paragraphe (`w:pPr/w:tabs/w:tab`) n'en sont pas —, la fin des paragraphes, les tableaux
//  (tabulation entre cellules, une ligne par rangée).
//  Ce qui est ignoré : codes de champ (`w:instrText`), texte supprimé (`w:del`, `w:moveFrom`), copie de repli d'une
//  zone de texte (`mc:Fallback`, sinon le texte y serait deux fois), séparateurs de notes.
//
//  Toute déclaration de type de document est refusée (entités externes ou récursives) : `shouldResolveExternalEntities`
//  reste faux ET la première déclaration abandonne la lecture. Le filtre de `WordXMLInputStream` l'empêche déjà
//  d'arriver jusqu'ici ; c'est la seconde ligne de défense.
//

import Foundation

nonisolated final class WordTextCollector: NSObject, XMLParserDelegate {
    static let transitionalNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let strictNamespace = "http://purl.oclc.org/ooxml/wordprocessingml/main"
    static let markupCompatibilityNamespace = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    private static let separatorNoteTypes: Set<String> = ["separator", "continuationSeparator", "continuationNotice"]
    private static let skippedContainers: Set<String> = ["del", "moveFrom"]

    private let characterBudget: Int
    private let stream: WordXMLInputStream

    private var text = ""
    private var emittedCount = 0
    private var skipDepth = 0
    private var runDepth = 0
    private var tableDepth = 0
    private var isInText = false
    private var elementDepth = 0

    /// Le budget de caractères est atteint : le collecteur a demandé l'arrêt, le reste du document n'est pas lu.
    private(set) var reachedBudget = false
    /// Une déclaration de type de document a été vue, ou l'imbrication dépasse `maxElementDepth` : fichier hostile.
    private(set) var sawDeclaration = false
    /// Profondeur d'éléments au-delà de laquelle le document est refusé (un vrai document en a moins d'une centaine,
    /// tableaux imbriqués compris).
    static let maxElementDepth = 512

    var collectedText: String { text }

    /// - Parameter characterBudget: caractères à réunir avant d'arrêter la lecture (la limite de l'appelant + 1,
    ///   pour savoir qu'il y avait davantage).
    init(characterBudget: Int, stream: WordXMLInputStream) {
        self.characterBudget = max(1, characterBudget)
        self.stream = stream
    }

    // MARK: Éléments

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        elementDepth += 1
        if elementDepth > Self.maxElementDepth {
            reject(parser)
            return
        }
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        if namespaceURI == Self.markupCompatibilityNamespace {
            if elementName == "Fallback" { skipDepth = 1 }
            return
        }
        guard Self.isWord(namespaceURI) else { return }

        if Self.skippedContainers.contains(elementName) {
            skipDepth = 1
            return
        }
        switch elementName {
        case "footnote", "endnote":
            if let type = Self.localAttribute("type", in: attributeDict), Self.separatorNoteTypes.contains(type) { skipDepth = 1 }
        case "r": runDepth += 1
        case "t": isInText = runDepth > 0
        case "tab", "ptab": if runDepth > 0 { append("\t", parser) }
        case "br", "cr": if runDepth > 0 { append("\n", parser) }
        case "noBreakHyphen": if runDepth > 0 { append("-", parser) }
        case "tbl": tableDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        elementDepth -= 1
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        guard Self.isWord(namespaceURI) else { return }
        switch elementName {
        case "t": isInText = false
        case "r": runDepth = max(0, runDepth - 1)
        case "p": endParagraph(parser)
        case "tc": endCell(parser)
        case "tr": endRow(parser)
        case "tbl": tableDepth = max(0, tableDepth - 1)
        default: break
        }
    }

    // MARK: Texte

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInText, skipDepth == 0 else { return }
        append(string, parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard isInText, skipDepth == 0, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        append(string, parser)
    }

    // MARK: Déclarations de type de document (toujours refusées)

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { reject(parser) }
    func parser(
        _ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
        type: String?, defaultValue: String?
    ) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser)
        return nil
    }

    private func reject(_ parser: XMLParser) {
        sawDeclaration = true
        stream.stop()
        parser.abortParsing()
    }

    // MARK: Construction du texte

    private func endParagraph(_ parser: XMLParser) {
        if tableDepth > 0 {
            // Dans une cellule : les paragraphes se suivent sur une même ligne.
            if let last = text.last, last != " ", last != "\t", last != "\n" { append(" ", parser) }
        } else {
            appendLineBreak(parser)
        }
    }

    private func endCell(_ parser: XMLParser) {
        trimTrailing([" "])
        append("\t", parser)
    }

    private func endRow(_ parser: XMLParser) {
        trimTrailing([" ", "\t"])
        appendLineBreak(parser)
    }

    /// Un saut de paragraphe : jamais plus d'une ligne vide d'affilée, jamais de blanc de fin de ligne.
    private func appendLineBreak(_ parser: XMLParser) {
        trimTrailing([" ", "\t"])
        guard !text.hasSuffix("\n\n") else { return }
        append("\n", parser)
    }

    private func trimTrailing(_ characters: Set<Character>) {
        while let last = text.last, characters.contains(last) {
            text.removeLast()
            emittedCount -= 1
        }
    }

    private func append(_ piece: String, _ parser: XMLParser) {
        guard !reachedBudget else { return }
        text += piece
        emittedCount += piece.count
        if emittedCount > characterBudget {
            reachedBudget = true
            stream.stop()
            parser.abortParsing()
        }
    }

    // MARK: Aides

    private static func isWord(_ namespace: String?) -> Bool {
        namespace == transitionalNamespace || namespace == strictNamespace
    }

    /// Valeur d'un attribut par son nom local (le préfixe, `w:type`, varie selon le document).
    private static func localAttribute(_ name: String, in attributes: [String: String]) -> String? {
        for (key, value) in attributes where key == name || key.hasSuffix(":" + name) { return value }
        return nil
    }
}
