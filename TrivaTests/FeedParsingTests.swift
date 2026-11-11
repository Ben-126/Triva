//
//  FeedParsingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Fixtures courtes copiées de VRAIS flux relevés le 2026-11-11 (structure et formats de
/// date conservés, texte raccourci) : un test avec un flux inventé ne prouverait pas que la
/// lecture tient face aux écarts réels entre éditeurs.
private enum FeedFixtures {
    /// ESPN : `CDATA` partout, fuseau nommé `EST`, aucune image.
    static let espn = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel><title>ESPN.com</title><link>https://www.espn.com</link>
    <image><title>ESPN</title><url>https://a.espncdn.com/logo.png</url></image>
    <item><title><![CDATA[Who's on the CFP bubble?]]></title>
    <description><![CDATA[A conference-by-conference look at who is close and who is out.]]></description>
    <dc:creator><![CDATA[Heather Dinich]]></dc:creator>
    <link><![CDATA[https://www.espn.com/college-football/story/_/id/50422353/cfp]]></link>
    <pubDate>Wed, 11 Nov 2026 00:45:22 EST</pubDate>
    <guid isPermaLink="false"><![CDATA[US-EN-50422353]]></guid></item>
    </channel></rss>
    """

    /// Variety : plusieurs `media:content` (le premier est l'image), `media:thumbnail`,
    /// entités numériques dans le titre, corps complet dans `content:encoded`.
    static let variety = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:media="http://search.yahoo.com/mrss/" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel><title>Variety</title>
    <item><title>&#8216;Adolescence&#8217; Writer Adapts &#8216;The Humans&#8217;</title>
    <link>https://variety.com/2026/theater/news/the-humans-1236944987/</link>
    <pubDate>Wed, 11 Nov 2026 10:00:00 +0000</pubDate>
    <description><![CDATA[Matt Smith will play an alien inside the body of a Cambridge academic.]]></description>
    <content:encoded><![CDATA[<p>LE CORPS COMPLET DE L'ARTICLE, À NE JAMAIS GARDER</p>]]></content:encoded>
    <media:content url="https://variety.com/wp-content/uploads/2026/11/first.jpg" medium="image" width="1000"/>
    <media:content url="https://variety.com/wp-content/uploads/2026/11/second.jpg" medium="image"/>
    <media:thumbnail url="https://variety.com/wp-content/uploads/2026/11/thumb.jpg"/></item>
    </channel></rss>
    """

    /// France 24 : `enclosure` audio d'un côté, image de l'autre ; `media:content` vidéo ignoré.
    static let enclosures = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
    <channel><item><title>Un podcast</title><link>https://example.test/a</link>
    <pubDate>Tue, 10 Nov 2026 21:30:00 +0000</pubDate>
    <enclosure url="https://example.test/a.mp3" type="audio/mpeg" length="1"/>
    <media:content url="https://example.test/a.mp4" medium="video"/></item>
    <item><title>Une photo</title><link>https://example.test/b</link>
    <pubDate>Tue, 10 Nov 2026 21:30:00 +0000</pubDate>
    <enclosure url="https://example.test/b.jpg" type="image/jpeg" length="1"/></item>
    <item><title>Sans type</title><link>https://example.test/c</link>
    <media:content url="https://example.test/c.png"/></item>
    </channel></rss>
    """

    /// The Conversation : Atom, `published` en `Z`, `summary` ET `content` (article entier).
    static let conversation = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xml:lang="en-US" xmlns="http://www.w3.org/2005/Atom">
      <id>tag:theconversation.com,2011:/fr/arts/articles</id>
      <title>Culture – The Conversation</title>
      <link rel="alternate" type="text/html" href="https://theconversation.com"/>
      <link rel="self" type="application/atom+xml" href="https://theconversation.com/fr/arts/articles.atom"/>
      <updated>2026-11-10T16:45:41Z</updated>
      <entry>
        <id>tag:theconversation.com,2011:article/294718</id>
        <published>2026-11-10T16:45:41Z</published>
        <updated>2026-11-10T17:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://theconversation.com/la-chanson-engagee-294718"/>
        <title>La chanson engagée selon Bernard Lavilliers</title>
        <content type="html">&lt;figure&gt;&lt;img src="https://images.example/a.jpg" /&gt;&lt;/figure&gt;&lt;p&gt;CORPS ENTIER&lt;/p&gt;</content>
        <summary>Comment tenir bon grâce à la musique.</summary>
      </entry>
    </feed>
    """
}

@Suite("FeedParser")
struct FeedParserTests {
    private func items(_ xml: String) throws -> [FeedItem] {
        try FeedParser.items(from: Data(xml.utf8))
    }

    @Test("RSS d'ESPN : CDATA, fuseau EST, entête de chaîne ignoré")
    func espn() throws {
        let parsed = try items(FeedFixtures.espn)
        #expect(parsed.count == 1)
        let item = try #require(parsed.first)
        #expect(item.title == "Who's on the CFP bubble?")
        #expect(item.link == "https://www.espn.com/college-football/story/_/id/50422353/cfp")
        #expect(item.summary == "A conference-by-conference look at who is close and who is out.")
        #expect(item.imageURL == nil)
        // 00:45:22 EST = 05:45:22 UTC.
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_794_375_922))
    }

    @Test("Variety : entités numériques décodées, première image media:content, corps jamais gardé")
    func variety() throws {
        let item = try #require(try items(FeedFixtures.variety).first)
        #expect(item.title == "‘Adolescence’ Writer Adapts ‘The Humans’")
        #expect(item.imageURL == "https://variety.com/wp-content/uploads/2026/11/first.jpg")
        #expect(item.summary == "Matt Smith will play an alien inside the body of a Cambridge academic.")
        #expect(item.summary?.contains("CORPS") == false)
    }

    @Test("une vidéo ou un son ne devient jamais une vignette ; une image sans type est reconnue par son extension")
    func onlyImagesBecomeThumbnails() throws {
        let parsed = try items(FeedFixtures.enclosures)
        #expect(parsed.map(\.imageURL) == [nil, "https://example.test/b.jpg", "https://example.test/c.png"])
    }

    @Test("Atom : lien alternate, date published, summary seul — le corps (content) est ignoré")
    func atom() throws {
        let parsed = try items(FeedFixtures.conversation)
        #expect(parsed.count == 1)
        let item = try #require(parsed.first)
        #expect(item.link == "https://theconversation.com/la-chanson-engagee-294718")
        #expect(item.title == "La chanson engagée selon Bernard Lavilliers")
        #expect(item.summary == "Comment tenir bon grâce à la musique.")
        // `published` (16:45:41Z) prime sur `updated` (17:00:00Z).
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_794_329_141))
        #expect(item.imageURL == nil)
    }

    @Test("un article sans titre ou sans lien est écarté, les autres restent")
    func incompleteItemsAreSkipped() throws {
        let xml = """
        <rss><channel>
        <item><title>Sans lien</title></item>
        <item><link>https://example.test/sans-titre</link></item>
        <item><title>Complet</title><link>https://example.test/ok</link></item>
        </channel></rss>
        """
        #expect(try items(xml).map(\.title) == ["Complet"])
    }

    @Test("un flux vide est valide : aucun article, aucune erreur")
    func emptyFeedIsValid() throws {
        #expect(try items("<rss><channel><title>Vide</title></channel></rss>").isEmpty)
    }

    @Test("une page qui n'est pas du XML lève .unreadable")
    func garbageThrows() {
        #expect(throws: FeedParseError.unreadable) {
            try FeedParser.items(from: Data("<html><body><p>Erreur 403".utf8))
        }
    }

    @Test("un flux coupé en route rend les articles déjà lus")
    func truncatedFeedKeepsReadItems() throws {
        let xml = "<rss><channel><item><title>Un</title><link>https://example.test/1</link></item><item><title>Deux"
        #expect(try items(xml).map(\.title) == ["Un"])
    }
}

@Suite("FeedText")
struct FeedTextTests {
    @Test("retire le balisage, décode les entités, fusionne les espaces")
    func plain() {
        let raw = "<div class=\"chapo\"><div>Google déploie&nbsp;Android&#160;17 &amp; ses <a href=\"x\">Pixel</a>.</div></div>\n"
        #expect(FeedText.plain(raw) == "Google déploie Android 17 & ses Pixel.")
    }

    @Test("deux paragraphes ne se collent pas")
    func blocksAreSeparated() {
        #expect(FeedText.plain("<p>Un</p><p>Deux</p>") == "Un Deux")
        #expect(FeedText.plain("Un<br/>Deux") == "Un Deux")
    }

    @Test("entités numériques, décimales et hexadécimales, et quelques noms usuels")
    func entities() {
        #expect(FeedText.plain("l&#8217;&#x2019;&hellip; &laquo;a&raquo;") == "l’’… «a»")
    }

    @Test("une entité inconnue ou mal formée reste telle quelle")
    func unknownEntitiesStay() {
        #expect(FeedText.plain("AT&T &inconnu; & fin") == "AT&T &inconnu; & fin")
    }

    @Test("le contenu d'un script ou d'un style n'est pas du texte")
    func scriptsAreDropped() {
        #expect(FeedText.plain("Avant<script>alert(1)</script>Après<style>p{}</style>") == "AvantAprès")
    }

    @Test("vide ou balises seules : nil")
    func emptyIsNil() {
        #expect(FeedText.plainOrNil("  <p> </p> ") == nil)
        #expect(FeedText.plainOrNil(nil) == nil)
        #expect(FeedText.plainOrNil("Texte") == "Texte")
    }

    @Test("un texte déjà brut n'est pas modifié (clause « ne pas modifier » d'ESPN et de PMC)")
    func plainTextIsUntouched() {
        let title = "Manchester United: Pochettino “open” to the job — sources say"
        #expect(FeedText.plain(title) == title)
    }
}

@Suite("FeedDate")
struct FeedDateTests {
    @Test("RFC 822 avec décalage numérique")
    func numericOffset() {
        #expect(FeedDate.parse("Wed, 11 Nov 2026 10:00:00 +0000") == Date(timeIntervalSince1970: 1_794_391_200))
        #expect(FeedDate.parse("Wed, 11 Nov 2026 11:00:00 +0100") == Date(timeIntervalSince1970: 1_794_391_200))
        #expect(FeedDate.parse("Wed, 11 Nov 2026 04:30:00 -0530") == Date(timeIntervalSince1970: 1_794_391_200))
    }

    @Test("RFC 822 avec fuseau nommé (ESPN)", arguments: [
        ("Wed, 11 Nov 2026 05:00:00 EST", 1_794_391_200),
        ("Wed, 11 Nov 2026 04:00:00 CST", 1_794_391_200),
        ("Wed, 11 Nov 2026 02:00:00 PST", 1_794_391_200),
        ("Wed, 11 Nov 2026 10:00:00 GMT", 1_794_391_200),
        ("Wed, 11 Nov 2026 10:00:00 UT", 1_794_391_200),
    ])
    func namedZone(text: String, expected: Int) {
        #expect(FeedDate.parse(text) == Date(timeIntervalSince1970: TimeInterval(expected)))
    }

    @Test("sans jour de semaine, sans secondes")
    func lenientRFC822() {
        #expect(FeedDate.parse("11 Nov 2026 10:00 GMT") == Date(timeIntervalSince1970: 1_794_391_200))
    }

    @Test("ISO 8601 : Z, décalage, avec et sans fractions de seconde")
    func iso8601() {
        #expect(FeedDate.parse("2026-11-11T10:00:00Z") == Date(timeIntervalSince1970: 1_794_391_200))
        #expect(FeedDate.parse("2026-11-11T11:00:00+01:00") == Date(timeIntervalSince1970: 1_794_391_200))
        #expect(FeedDate.parse("2026-11-11T10:00:00.250Z") == Date(timeIntervalSince1970: 1_794_391_200.25))
    }

    @Test("texte illisible : nil, jamais une date inventée", arguments: [
        "", "   ", "hier", "Wed, 99 Foo 2026 10:00:00 GMT", "Wed, 11 Nov 2026 10:00:00 XYZ", "2026-13-45",
    ])
    func unreadable(text: String) {
        #expect(FeedDate.parse(text) == nil)
    }
}
