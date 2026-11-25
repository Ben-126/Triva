//
//  PasteboardClassifierTests.swift
//  TrivaTests
//
//  K2 : que faire d'un Cmd+V. La règle : le TEXTE gagne (collage normal dans le champ), sauf si le presse-papiers
//  porte un fichier (Finder, Fichiers) ; une image seule, ou une image accompagnée de sa seule adresse web
//  (« Copier l'image » de Safari), est jointe. Cas écrits d'après de vrais presse-papiers.
//

import Foundation
import Testing
@testable import Triva

@Suite("Collage — classement du presse-papiers")
struct PasteboardClassifierTests {
    private let file = URL(fileURLWithPath: "/Users/ben/Documents/rapport.pdf")

    @Test("Texte seul : collage de texte normal")
    func plainText() {
        #expect(PasteboardClassifier.decision(for: .init(text: "Capitale du Japon ?")) == .text)
    }

    @Test("Lien web seul : du texte")
    func webLinkOnly() {
        #expect(PasteboardClassifier.decision(for: .init(text: "https://exemple.fr/page")) == .text)
    }

    @Test("Copie dans le Finder ou Fichiers (adresse de fichier + nom en texte + icône) : le fichier")
    func finderCopy() {
        let snapshot = PasteboardSnapshot(fileURLs: [file], hasImage: true, text: "rapport.pdf")
        #expect(PasteboardClassifier.decision(for: snapshot) == .files)
    }

    @Test("Plusieurs fichiers : les fichiers")
    func severalFiles() {
        let snapshot = PasteboardSnapshot(fileURLs: [file, file.deletingLastPathComponent().appendingPathComponent("notes.md")])
        #expect(PasteboardClassifier.decision(for: snapshot) == .files)
    }

    @Test("Capture d'écran (image seule) : l'image")
    func screenshot() {
        #expect(PasteboardClassifier.decision(for: .init(hasImage: true)) == .image)
    }

    @Test("Safari « Copier l'image » (image + son adresse web) : l'image")
    func safariCopyImage() {
        let snapshot = PasteboardSnapshot(hasImage: true, text: "https://exemple.fr/photos/tableau.png")
        #expect(PasteboardClassifier.decision(for: snapshot) == .image)
    }

    @Test("Cellule de tableur (texte + image du rendu) : le texte")
    func spreadsheetCell() {
        let snapshot = PasteboardSnapshot(hasImage: true, text: "12,5")
        #expect(PasteboardClassifier.decision(for: snapshot) == .text)
    }

    @Test("Texte riche copié d'une page (texte seul côté classement) : le texte")
    func richText() {
        #expect(PasteboardClassifier.decision(for: .init(text: "Un paragraphe copié.\nEt un second.")) == .text)
    }

    @Test("Image accompagnée d'une phrase (pas une adresse) : le texte")
    func imageWithSentence() {
        let snapshot = PasteboardSnapshot(hasImage: true, text: "voir https://exemple.fr ci-dessous")
        #expect(PasteboardClassifier.decision(for: snapshot) == .text)
    }

    @Test("Presse-papiers vide, ou texte blanc : rien")
    func nothing() {
        #expect(PasteboardClassifier.decision(for: .init()) == .nothing)
        #expect(PasteboardClassifier.decision(for: .init(text: "  \n ")) == .nothing)
    }

    @Test("Un .docx copié du Finder est classé « fichier » : c'est le dépôt qui le refuse, avec son message")
    func docxIsRefusedByTheDropPath() {
        let docx = URL(fileURLWithPath: "/Users/ben/Documents/lettre.docx")
        #expect(PasteboardClassifier.decision(for: .init(fileURLs: [docx])) == .files)
        let item = DroppedItem.fromURL(docx)
        #expect(item == .refused(.unsupportedType))
        #expect(DropPlan(items: [item]).refusalMessage == DropRefusal.unsupportedTypeMessage)
    }
}

@Suite("Collage — fournisseurs iOS")
struct PasteboardProviderSnapshotTests {
    @Test("Un fichier détecté sans adresse lue (iOS) est classé « fichier »")
    func fileItemWithoutURL() {
        #expect(PasteboardClassifier.decision(for: .init(hasFileItem: true, hasImage: true, text: "nom.pdf")) == .files)
    }
}
