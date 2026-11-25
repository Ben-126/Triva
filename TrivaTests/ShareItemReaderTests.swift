//
//  ShareItemReaderTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : ce que l'extension de partage comprend de ce qu'on lui envoie (texte, page web,
//  PDF, image). On construit de vrais `NSExtensionItem` / `NSItemProvider`, comme le fait le système.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Triva

private struct ReaderFixture {
    let root: URL
    let staging: URL

    init() throws {
        root = try TestFiles.makeFolder("reader")
        staging = root.appendingPathComponent("staging", isDirectory: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }

    /// Un fournisseur de fichier comme celui d'une app source : le système en fait une copie temporaire au nom d'origine.
    func fileProvider(_ data: Data, named name: String) throws -> NSItemProvider {
        let url = try TestFiles.write(data, named: name, in: root)
        let provider = NSItemProvider()
        let type = try #require(UTType(filenameExtension: (name as NSString).pathExtension))
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    func leftoversInStaging() -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: staging.path).filter { !$0.isEmpty }) ?? []
    }
}

@MainActor
@Suite("Partage — lecture de ce qui est partagé")
struct ShareItemReaderTests {
    @Test("Un texte partagé est lu tel quel")
    func plainText() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let provider = NSItemProvider(object: "Qui a inventé le vélo ?" as NSString)
        let content = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        #expect(content == .text("Qui a inventé le vélo ?"))
    }

    @Test("Une page web partagée depuis Safari : le TITRE (du prétraitement) est préféré à l'adresse")
    func safariPageUsesTitle() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let url = try #require(URL(string: "https://exemple.fr/article?id=4"))
        let urlProvider = NSItemProvider(object: url as NSURL)
        let results: NSDictionary = [
            NSExtensionJavaScriptPreprocessingResultsKey: ["title": "Les volcans d'Islande", "url": "https://exemple.fr/article?id=4"],
        ]
        let plistProvider = NSItemProvider(item: results, typeIdentifier: UTType.propertyList.identifier)
        let content = try await ShareItemReader.read([fixture.item([urlProvider, plistProvider])], stagingDirectory: fixture.staging)
        #expect(content == .page(title: "Les volcans d'Islande", url: url))
        #expect(content.suggestedQuestion == "Les volcans d'Islande")
    }

    @Test("Une adresse seule : la question proposée est l'adresse elle-même")
    func urlAloneFallsBackToTheAddress() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let url = try #require(URL(string: "https://exemple.fr/article"))
        let content = try await ShareItemReader.read([fixture.item([NSItemProvider(object: url as NSURL)])], stagingDirectory: fixture.staging)
        #expect(content == .page(title: nil, url: url))
        #expect(content.suggestedQuestion == "https://exemple.fr/article")
    }

    @Test("Un titre vide ou fait de caractères invisibles retombe sur l'adresse")
    func blankTitleFallsBack() {
        let url = URL(string: "https://exemple.fr/a")!
        #expect(ShareContent.page(title: " \u{200B}\u{202E} ", url: url).suggestedQuestion == "https://exemple.fr/a")
        #expect(ShareContent.text("  \u{200B}  ").suggestedQuestion == nil)
        #expect(ShareContent.text("Bonjour\u{202E}\t!").suggestedQuestion == "Bonjour !")
    }

    @Test("Une adresse qui n'est pas une page web (javascript:, file:, mailto:) n'est pas lue")
    func nonWebURLsAreRefused() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "mailto:a@b.fr", "data:text/html,<b>x</b>"] {
            let url = try #require(URL(string: raw))
            await #expect(throws: ShareReadError.nothingReadable) {
                _ = try await ShareItemReader.read([fixture.item([NSItemProvider(object: url as NSURL)])], stagingDirectory: fixture.staging)
            }
        }
    }

    @Test("Un PDF est copié dans le dossier de travail de l'extension, sans passer par la mémoire")
    func pdfFile() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let bytes = SampleBytes.pdf(padding: 500)
        let provider = try fixture.fileProvider(bytes, named: "Cours de maths.pdf")
        let content = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        guard case .file(let file) = content else { Issue.record("fichier attendu, reçu \(content)"); return }
        #expect(file.type == .pdf)
        #expect(file.displayName == "Cours de maths.pdf", "nom reçu : \(file.displayName)")
        #expect(file.byteCount == bytes.count)
        #expect(try Data(contentsOf: file.url) == bytes)
        #expect(file.url.standardizedFileURL.path.hasPrefix(fixture.staging.standardizedFileURL.path + "/"))
        #expect(content.suggestedQuestion == nil)
    }

    @Test("Une image est reconnue par son contenu, quel que soit son nom")
    func imageFile() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let provider = try fixture.fileProvider(SampleBytes.png(), named: "capture.png")
        let content = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        guard case .file(let file) = content else { Issue.record("fichier attendu"); return }
        #expect(file.type == .png)
        #expect(file.displayName == "capture.png", "nom reçu : \(file.displayName)")
    }

    @Test("Fichier malveillant : un exécutable nommé .pdf est refusé et rien ne reste dans le dossier de travail")
    func maliciousFile() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let provider = try fixture.fileProvider(SampleBytes.executable(), named: "facture.pdf")
        await #expect(throws: ShareReadError.unsupportedFile) {
            _ = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        }
        #expect(fixture.leftoversInStaging().filter { !$0.isEmpty }.allSatisfy { !$0.contains(".") }, "aucun fichier ne reste")
    }

    @Test("Un fichier de plus de 200 Mo est refusé sans être copié")
    func oversizedFile() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let big = try TestFiles.writeSparse(header: SampleBytes.pdf(), size: SharedFileType.pdf.maxByteCount + 1, named: "gros.pdf", in: fixture.root)
        let provider = try #require(NSItemProvider(contentsOf: big))
        await #expect(throws: ShareReadError.tooLarge) {
            _ = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        }
        #expect(fixture.leftoversInStaging().allSatisfy { !$0.hasSuffix(".pdf") })
    }

    @Test("Rien de lisible : aucun élément, pièce jointe vide, type inconnu")
    func nothingReadable() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        await #expect(throws: ShareReadError.nothingReadable) {
            _ = try await ShareItemReader.read([], stagingDirectory: fixture.staging)
        }
        await #expect(throws: ShareReadError.nothingReadable) {
            _ = try await ShareItemReader.read([NSExtensionItem()], stagingDirectory: fixture.staging)
        }
    }

    @Test("Nettoyage : vider le dossier de travail efface le fichier copié")
    func cleaningStaging() async throws {
        let fixture = try ReaderFixture(); defer { fixture.cleanUp() }
        let provider = try fixture.fileProvider(SampleBytes.pdf(), named: "a.pdf")
        _ = try await ShareItemReader.read([fixture.item([provider])], stagingDirectory: fixture.staging)
        #expect(!fixture.leftoversInStaging().isEmpty)
        ShareItemReader.clearStaging(at: fixture.staging)
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }
}
