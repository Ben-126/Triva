//
//  FeedAuthorTests.swift
//  TrivaTests
//
//  Auteur des articles Découvrir : la licence CC BY-ND 4.0 de The Conversation exige de le citer.
//

import Testing
import Foundation
@testable import Triva

struct FeedAuthorTests {
    /// Extrait Atom au format de The Conversation : `<author><name>` imbriqué, plusieurs auteurs possibles.
    private let atom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>The Conversation</title>
    <author><name>Flux entier</name></author>
    <entry><title>Pourquoi les abeilles dansent</title>
    <link href="https://theconversation.com/abeilles-123" rel="alternate"/>
    <published>2026-11-11T10:00:00Z</published>
    <author>
      <name>Claire Martin</name>
      <uri>https://theconversation.com/profiles/claire-martin</uri>
    </author>
    <author><name>Paul Durand</name></author>
    <summary>Un extrait.</summary></entry>
    <entry><title>Sans auteur</title>
    <link href="https://theconversation.com/sans-auteur-1" rel="alternate"/></entry>
    </feed>
    """

    @Test("Atom : <author><name> lu, plusieurs auteurs réunis, le <name> du flux ignoré")
    func atomAuthors() throws {
        let items = try FeedParser.items(from: Data(atom.utf8))
        #expect(items.count == 2)
        #expect(items[0].author == "Claire Martin, Paul Durand")
        #expect(items[1].author == nil)
    }

    @Test("RSS : dc:creator d'abord, <author> sans adresse e-mail")
    func rssAuthors() throws {
        let rss = """
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>
        <item><title>A</title><link>https://exemple.fr/a</link><dc:creator><![CDATA[Heather Dinich]]></dc:creator>
        <author>x@exemple.fr (Autre Nom)</author></item>
        <item><title>B</title><link>https://exemple.fr/b</link><author>jean@exemple.fr (Jean Dupont)</author></item>
        <item><title>C</title><link>https://exemple.fr/c</link><author>secret@exemple.fr</author></item>
        </channel></rss>
        """
        let items = try FeedParser.items(from: Data(rss.utf8))
        #expect(items.map(\.author) == ["Heather Dinich", "Jean Dupont", nil])
    }

    @Test("ligne méta : « Par {auteur} · {média} », sinon le média seul")
    func metaLine() {
        #expect(DiscoverArticlePresentation.metaLine(author: "Claire Martin", source: "The Conversation", age: nil)
            == "Par Claire Martin · The Conversation")
        #expect(DiscoverArticlePresentation.metaLine(author: nil, source: "The Conversation", age: "hier")
            == "The Conversation · hier")
        #expect(DiscoverArticlePresentation.metaLine(author: "  ", source: "ESPN", age: nil) == "ESPN")
    }

    @Test("ligne méta affichée : seul l'auteur est tronquable, le média reste dans `trail`")
    func metaPartsKeepSource() {
        let long = "Claire Martin, Professeure des universités, spécialiste de l'abeille mellifère et des pollinisateurs"
        let parts = DiscoverArticlePresentation.metaParts(author: long, source: "The Conversation", age: "hier")
        #expect(parts.lead == "Par \(long)")
        #expect(parts.trail == "The Conversation · hier")
        #expect(DiscoverArticlePresentation.metaParts(author: nil, source: "ESPN", age: nil) == (nil, "ESPN"))
        #expect(DiscoverArticlePresentation.metaParts(author: "Jean", source: nil, age: nil) == ("Par Jean", nil))
        let full = DiscoverArticlePresentation.metaLine(author: long, source: "The Conversation", age: "hier")
        #expect(full == "\(parts.lead!) · \(parts.trail!)")
    }

    @Test("le cache relit l'auteur, et un ancien fichier sans auteur reste lisible")
    func cacheBackwardCompatible() throws {
        let old = #"{"title":"T","url":"https://e.fr/a","snippet":null,"imageURL":null,"publishedAt":null,"sourceName":"E","allowsAIUse":true}"#
        let decoded = try JSONDecoder().decode(DiscoverCacheSnapshot.Article.self, from: Data(old.utf8))
        #expect(decoded.author == nil)
        let withAuthor = DiscoverCacheSnapshot.Article(
            title: "T", url: "https://e.fr/a", snippet: nil, imageURL: nil, publishedAt: nil,
            sourceName: "E", allowsAIUse: true, author: "Claire Martin")
        let round = try JSONDecoder().decode(DiscoverCacheSnapshot.Article.self, from: JSONEncoder().encode(withAuthor))
        #expect(round.author == "Claire Martin")
    }
}
