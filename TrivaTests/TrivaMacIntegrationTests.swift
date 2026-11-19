//
//  TrivaMacIntegrationTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M7) : Services, menu du Dock et Info.plist du Mac.
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Mac — Info.plist et Services")
struct TrivaMacInfoPlistTests {
    /// L'app est l'hôte des tests : `Bundle.main` est le vrai `Triva.app`, donc le plist FUSIONNÉ.
    private var services: [[String: Any]] {
        Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? []
    }

    @Test("Le plist fusionné déclare le service « Rechercher avec Triva »")
    func serviceIsDeclared() throws {
        let service = try #require(services.first)
        let menuItem = try #require(service["NSMenuItem"] as? [String: String])
        #expect(menuItem["default"] == "Rechercher avec Triva")
        #expect(service["NSMessage"] as? String == "searchWithTriva")
        #expect(service["NSSendTypes"] as? [String] == ["public.utf8-plain-text"])
        #expect(service["NSReturnTypes"] == nil)
        #expect(service["NSPortName"] as? String == "Triva")
    }

    @Test("Le plist fusionné garde les clés générées d'avant")
    func generatedKeysSurvive() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
        #expect(info["CFBundleIdentifier"] != nil)
        #expect(info["LSMinimumSystemVersion"] != nil)
    }

    @Test("Le message du plist correspond à une vraie méthode du fournisseur")
    func messageMatchesProvider() throws {
        let message = try #require(services.first?["NSMessage"] as? String)
        let selector = NSSelectorFromString("\(message):userData:error:")
        #expect(selector == TrivaServicesProvider.serviceSelector)
        #expect(TrivaServicesProvider.instancesRespond(to: selector))
    }
}

@MainActor
@Suite("Mac — fournisseur de Services")
struct TrivaServicesProviderTests {
    @Test("Du texte sélectionné ouvre une recherche pré-remplie")
    func deliversText() throws {
        let launcher = ExternalSearchLauncher()
        let provider = TrivaServicesProvider(launcher: launcher)
        #expect(provider.deliver(text: "  Définition de « sérendipité »\n") == nil)
        guard case .newSearch(let id) = try #require(launcher.drain().first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        #expect(launcher.inbox.take(for: id) == "Définition de « sérendipité »")
    }

    @Test("Aucun texte : le message du système, rien d'ouvert")
    func rejectsEmpty() {
        let launcher = ExternalSearchLauncher()
        let provider = TrivaServicesProvider(launcher: launcher)
        #expect(provider.deliver(text: nil) == "Aucun texte sélectionné.")
        #expect(provider.deliver(text: " \n\t ") == "Aucun texte sélectionné.")
        #expect(launcher.drain().isEmpty)
    }

    @Test("Le point d'entrée Objective-C lit le presse-papiers du service")
    func readsPasteboard() throws {
        let launcher = ExternalSearchLauncher()
        let provider = TrivaServicesProvider(launcher: launcher)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Capitale de l'Australie", forType: .string)

        var message: NSString?
        withUnsafeMutablePointer(to: &message) { pointer in
            provider.searchWithTriva(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
        }
        #expect(message == nil)
        guard case .newSearch(let id) = try #require(launcher.drain().first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        #expect(launcher.inbox.take(for: id) == "Capitale de l'Australie")
    }
}

@MainActor
@Suite("Mac — menu du Dock")
struct TrivaDockMenuTests {
    @Test("Une seule entrée « Nouvelle recherche », qui ouvre une recherche neuve")
    func newSearchItem() throws {
        let launcher = ExternalSearchLauncher()
        let delegate = TrivaMacAppDelegate(launcher: launcher)
        let menu = delegate.makeDockMenu()
        #expect(menu.items.count == 1)
        let item = try #require(menu.items.first)
        #expect(item.title == "Nouvelle recherche")
        #expect(item.isEnabled)
        #expect(item.target === delegate)

        // Choisir l'entrée : exactement la demande de la barre des menus (une recherche neuve).
        let action = try #require(item.action)
        _ = delegate.perform(action)
        let targets = launcher.drain()
        #expect(targets.count == 1)
        guard case .newSearch = try #require(targets.first) else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
    }

    @Test("À la sortie de l'app, les copies temporaires de pièces jointes sont effacées")
    func terminationPurgesAttachmentCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DelegateVault-\(UUID().uuidString)", isDirectory: true)
        let copy = root.appendingPathComponent("session/id/rapport.pdf")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("document privé".utf8).write(to: copy)
        defer { try? FileManager.default.removeItem(at: root) }

        let delegate = TrivaMacAppDelegate(launcher: ExternalSearchLauncher(), attachmentVaultRoot: root)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Sans dossier de copies (app hébergeant les tests), la sortie n'efface rien")
    func terminationWithoutVaultRootDoesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DelegateNoVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = TrivaMacAppDelegate(launcher: ExternalSearchLauncher(), attachmentVaultRoot: nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Le menu du Dock est celui du délégué")
    func delegateReturnsMenu() {
        let delegate = TrivaMacAppDelegate(launcher: ExternalSearchLauncher())
        #expect(delegate.applicationDockMenu(NSApplication.shared)?.items.first?.title == "Nouvelle recherche")
    }
}
#endif
