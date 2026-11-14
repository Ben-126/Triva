//
//  MissionC3PresentationTests.swift
//  TrivaTests
//
//  Mission C3 : logique pure des écrans (revue R3-3, R3-5).
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("Mission C3 — présentation")
struct MissionC3PresentationTests {
    private func source(_ url: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: "Titre", url: url, content: nil, imgSrc: nil, thumbnailSrc: nil,
            thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    @Test("Une source web http ou https s'ouvre")
    func webSourcesAreOpenable() {
        #expect(SourcesListPresentation.openableURL(for: source("https://www.lemonde.fr/a")) != nil)
        #expect(SourcesListPresentation.openableURL(for: source("http://example.com")) != nil)
        #expect(SourcesListPresentation.openableURL(for: source("HTTPS://example.com")) != nil)
    }

    @Test("Un schéma qui ouvre une autre app n'est jamais un lien de source",
          arguments: [
              "facetime://x@example.com", "tel://example.com", "shortcuts://example.com/run-shortcut?name=a",
              "mailto:a@example.com", "sms://example.com", "javascript:alert(1)", "triva-attachment:abc", "pas une url",
          ])
    func foreignSchemesAreNotOpenable(url: String) {
        #expect(SourcesListPresentation.openableURL(for: source(url)) == nil)
    }

    @Test("Le recentrage à l'apparition n'a lieu que pour une conversation pas encore positionnée")
    func positionsOnAppearOnlyForANewConversation() {
        let conversation = UUID()
        #expect(ChatScrollFollowing.shouldPositionOnAppear(current: conversation, lastPositioned: nil))
        #expect(ChatScrollFollowing.shouldPositionOnAppear(current: conversation, lastPositioned: UUID()))
        // Retour sur l'onglet Recherche : la position de lecture est gardée.
        #expect(!ChatScrollFollowing.shouldPositionOnAppear(current: conversation, lastPositioned: conversation))
        #expect(!ChatScrollFollowing.shouldPositionOnAppear(current: nil, lastPositioned: nil))
    }
}
