//
//  LegalLinksTests.swift
//  TrivaTests
//
//  Mission C3 : liens légaux, signalement, routage des liens vers le navigateur intégré.
//

import Foundation
import Testing
@testable import Triva

@Suite("Liens légaux et navigateur intégré")
struct LegalLinksTests {
    private let base = URL(string: "https://exemple.test/Triva/")!

    @Test("Les quatre pages publiques sont sous la base, en .html")
    func pageURLs() {
        #expect(LegalLinks.url(for: .privacy, base: base).absoluteString == "https://exemple.test/Triva/confidentialite.html")
        #expect(LegalLinks.url(for: .terms, base: base).absoluteString == "https://exemple.test/Triva/conditions.html")
        #expect(LegalLinks.url(for: .legalNotice, base: base).absoluteString == "https://exemple.test/Triva/mentions-legales.html")
        #expect(LegalLinks.url(for: .support, base: base).absoluteString == "https://exemple.test/Triva/assistance.html")
    }

    @Test("La base réelle est une adresse https qui se termine par une barre")
    func realBase() {
        #expect(LegalLinks.baseURL.scheme == "https")
        #expect(LegalLinks.baseURL.absoluteString.hasSuffix("/"))
        for page in LegalLinks.Page.allCases {
            #expect(LegalLinks.url(for: page).absoluteString.hasPrefix(LegalLinks.baseURL.absoluteString))
        }
    }

    @Test("L'e-mail de support n'est pas défini : aucun faux contact dans l'app")
    func supportEmailIsUndefined() {
        #expect(LegalLinks.supportEmail.isEmpty)
    }

    @Test("Sans e-mail de support, « Signaler un problème » ouvre la page d'assistance")
    func reportFallsBackToSupportPage() {
        #expect(LegalLinks.reportDestination(supportEmail: "", base: base) == LegalLinks.url(for: .support, base: base))
        #expect(LegalLinks.reportDestination(supportEmail: "   \n", base: base) == LegalLinks.url(for: .support, base: base))
    }

    @Test("Avec un e-mail de support, un mailto: avec sujet et consigne, sans rien de la conversation")
    func reportBuildsMailto() throws {
        let url = LegalLinks.reportDestination(supportEmail: "aide@exemple.test", base: base)
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "aide@exemple.test")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"] == AboutText.reportMailSubject)
        #expect(items["body"] == AboutText.reportMailBody)
        // La route d'un mailto: reste externe : jamais dans le navigateur intégré.
        #expect(LinkRouting.route(for: url) == .system)
    }

    @Test("La ligne de version reprend « Version {version} ({build}) »")
    func versionLine() {
        #expect(AboutText.versionLine(version: "1.2", build: "34") == "Version 1.2 (34)")
    }

    @Test(
        "Seules les pages http(s) avec un hôte s'ouvrent dans l'app",
        arguments: [
            ("https://fr.wikipedia.org/wiki/Tokyo", LinkRouting.Route.inApp),
            ("HTTP://exemple.test/page", .inApp),
            ("mailto:aide@exemple.test", .system),
            ("tel:+33123456789", .system),
            ("file:///etc/hosts", .system),
            ("https:///sans-hote", .system),
            ("javascript:alert(1)", .system),
            ("triva://citation/1", .system),
        ]
    )
    func routing(address: String, expected: LinkRouting.Route) throws {
        let url = try #require(URL(string: address))
        #expect(LinkRouting.route(for: url) == expected)
    }

    @Test("Les liens légaux publics passent tous par le navigateur intégré")
    func legalLinksOpenInApp() {
        for page in LegalLinks.Page.allCases {
            #expect(LinkRouting.route(for: LegalLinks.url(for: page)) == .inApp)
        }
    }
}
