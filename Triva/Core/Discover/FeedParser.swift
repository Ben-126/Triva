//
//  FeedParser.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Flux illisible : ni RSS ni Atom, ou XML trop abîmé pour en tirer un seul article.
nonisolated enum FeedParseError: Error, Sendable, Equatable {
    case unreadable
}

/// Lecteur `XMLParser` de flux RSS 2.0 et Atom, sans dépendance (même méthode que
/// `ArXivAtomParser`).
///
/// - `shouldProcessNamespaces` reste à `false` : les éléments arrivent avec leur préfixe
///   (`media:content`, `dc:date`, `content:encoded`), ce qui évite de dépendre du préfixe
///   choisi par chaque éditeur dans sa déclaration `xmlns`... et d'un nom qualifié ambigu.
/// - Pas d'entités externes (`shouldResolveExternalEntities == false`) : pas de vecteur
///   XXE sur une réponse réseau.
/// - Le texte n'est accumulé que pour les éléments utiles. Le corps des articles
///   (`content`, `content:encoded`) n'est JAMAIS gardé (voir `FeedItem`), ce qui évite aussi
///   de copier 800 Ko de HTML pour rien.
/// - Un flux coupé en cours de route rend les articles déjà lus plutôt que rien.
nonisolated final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [FeedItem] = []
    private var current: PartialItem?
    private var captured: String?
    private var buffer = ""

    /// Image candidate par ordre de préférence : `media:content` > `media:thumbnail` >
    /// `enclosure`. Variety envoie plusieurs `media:content` par article : on garde le premier.
    private struct PartialItem {
        var title = ""
        var link = ""
        var summary = ""
        var published = ""
        var updated = ""
        var mediaContent: String?
        var mediaThumbnail: String?
        var enclosure: String?
    }

    /// Éléments dont on garde le texte, dans un article.
    private static let capturedElements: Set<String> = [
        "title", "link", "description", "summary", "pubDate", "published", "updated", "dc:date",
    ]

    static func items(from data: Data) throws(FeedParseError) -> [FeedItem] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let completed = parser.parse()
        if !completed && delegate.items.isEmpty { throw .unreadable }
        return delegate.items
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "item" || elementName == "entry" {
            current = PartialItem()
            return
        }
        guard current != nil else { return }
        buffer = ""
        captured = Self.capturedElements.contains(elementName) ? elementName : nil
        switch elementName {
        case "link": readAtomLink(attributeDict)
        case "media:content": readMediaContent(attributeDict)
        case "media:thumbnail": readMediaThumbnail(attributeDict)
        case "enclosure": readEnclosure(attributeDict)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captured != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if captured != nil { buffer += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item" || elementName == "entry" {
            if let finished = current, let item = Self.makeItem(finished) { items.append(item) }
            current = nil
            captured = nil
            return
        }
        guard current != nil, captured == elementName else { return }
        store(buffer, for: elementName)
        captured = nil
        buffer = ""
    }

    // MARK: Lecture d'un article

    private func store(_ text: String, for element: String) {
        switch element {
        case "title": current?.title = text
        case "link": if current?.link.isEmpty ?? false { current?.link = text }
        case "description", "summary": current?.summary = text
        case "pubDate", "published", "dc:date": if current?.published.isEmpty ?? false { current?.published = text }
        case "updated": current?.updated = text
        default: break
        }
    }

    /// Atom : `<link href="…" rel="alternate"/>`. Les liens `self`, `enclosure`, `replies`…
    /// ne sont pas la page de l'article. En RSS, `<link>` porte l'adresse comme texte :
    /// sans attribut `href`, cette fonction ne fait rien et `store` prend le texte.
    private func readAtomLink(_ attributes: [String: String]) {
        guard let href = attributes["href"] else { return }
        let rel = attributes["rel"] ?? "alternate"
        if rel == "alternate", current?.link.isEmpty ?? false { current?.link = href }
    }

    /// `media:content` n'est une vignette que si c'est une image : `medium="image"` ou un
    /// type `image/*`. Sans l'un ni l'autre, on regarde l'extension (certains éditeurs
    /// n'écrivent que l'adresse). Une vidéo ou un son ne devient jamais une vignette.
    private func readMediaContent(_ attributes: [String: String]) {
        guard current?.mediaContent == nil, let url = attributes["url"] else { return }
        let medium = attributes["medium"]?.lowercased()
        let type = attributes["type"]?.lowercased()
        let isImage = medium == "image"
            || type?.hasPrefix("image/") == true
            || (medium == nil && type == nil && Self.looksLikeImage(url))
        if isImage { current?.mediaContent = url }
    }

    private func readMediaThumbnail(_ attributes: [String: String]) {
        if current?.mediaThumbnail == nil { current?.mediaThumbnail = attributes["url"] }
    }

    private func readEnclosure(_ attributes: [String: String]) {
        guard current?.enclosure == nil, let url = attributes["url"] else { return }
        let type = attributes["type"]?.lowercased()
        if type?.hasPrefix("image/") == true || (type == nil && Self.looksLikeImage(url)) {
            current?.enclosure = url
        }
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let path = (URL(string: url)?.path() ?? url).lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"].contains { path.hasSuffix($0) }
    }

    /// Un article sans titre ou sans adresse n'est pas affichable : il est écarté ici.
    private static func makeItem(_ partial: PartialItem) -> FeedItem? {
        let title = FeedText.plain(partial.title)
        let link = partial.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty else { return nil }
        let dateText = partial.published.isEmpty ? partial.updated : partial.published
        return FeedItem(
            title: title,
            link: link,
            summary: FeedText.plainOrNil(partial.summary),
            imageURL: partial.mediaContent ?? partial.mediaThumbnail ?? partial.enclosure,
            publishedAt: FeedDate.parse(dateText)
        )
    }
}
