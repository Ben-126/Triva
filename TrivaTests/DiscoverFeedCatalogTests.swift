//
//  DiscoverFeedCatalogTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Garde-fous du catalogue de flux : ce qui y entre a été lu et validé (voir
/// `DiscoverFeedCatalog`), et un ajout par erreur doit casser un test.
@Suite("DiscoverFeedCatalog")
struct DiscoverFeedCatalogTests {
    @Test("toutes les adresses sont valides, en https, avec une page de conditions")
    func addressesAreWellFormed() {
        for source in DiscoverFeedCatalog.allSources {
            #expect(source.url.scheme == "https", "\(source.id) : flux non https")
            #expect(source.url.host()?.isEmpty == false, "\(source.id) : hôte manquant")
            #expect(source.termsURL.scheme == "https", "\(source.id) : conditions non https")
            #expect(source.termsURL.host()?.isEmpty == false, "\(source.id) : hôte des conditions manquant")
            #expect(!source.name.isEmpty)
        }
    }

    @Test("les identifiants sont uniques")
    func identifiersAreUnique() {
        let ids = DiscoverFeedCatalog.allSources.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("aucun éditeur exclu pour ses conditions d'usage n'est dans le catalogue")
    func excludedPublishersAreAbsent() {
        let excluded = [
            "lemonde.fr", "bbc.co", "bbc.com", "theguardian.com", "marketwatch.com", "wired.com",
            "arstechnica.com", "techcrunch.com", "theverge.com", "npr.org", "radio-canada.ca",
            "beauxarts.com", "connaissancedesarts.com", "telerama.fr", "franceinfo.fr", "allocine.fr",
            "hyperallergic.com", "theartnewspaper.com", "maxifoot", "ecranlarge.com",
        ]
        for source in DiscoverFeedCatalog.allSources {
            let host = source.url.host() ?? ""
            #expect(!excluded.contains { host.contains($0) }, "\(source.id) : éditeur exclu (\(host))")
        }
    }

    @Test("The Conversation n'affiche pas ses images (droits tiers), les autres sources oui")
    func conversationHasNoThumbnails() {
        for source in DiscoverFeedCatalog.allSources {
            #expect(source.usesThumbnails == (source.name != "The Conversation"), "\(source.id)")
        }
    }

    @Test("le sport en français n'a pas de flux propre : repli sur l'anglais")
    func frenchSportsFallsBack() {
        let resolved = DiscoverFeedCatalog.resolvedSources(for: .sports, language: .french)
        #expect(resolved.isFallback)
        #expect(resolved.sources == DiscoverFeedCatalog.sources(for: .sports, language: .english))
        #expect(!DiscoverFeedCatalog.resolvedSources(for: .tech, language: .french).isFallback)
    }
}
