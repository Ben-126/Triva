//
//  PasteAndTruncationTests.swift
//  TrivaTests
//
//  K2 : ce que le chat fait d'un collage ou d'un dépôt (plan, filtre, application au contrôleur), et l'annonce,
//  discrète, d'un texte externe coupé à 2000 caractères.
//

import Foundation
import Testing
@testable import Triva

@Suite("Dépôt et collage — plan")
struct DropPlanPasteTests {
    private let limit = ExternalQuerySanitizer.maxLength

    @Test("Un texte déposé de plus de 2000 caractères est coupé ET signalé")
    func longDroppedTextIsReported() {
        let plan = DropPlan(items: [.text(String(repeating: "a", count: limit + 40))])
        #expect(plan.draftTexts.first?.count == limit)
        #expect(plan.hasTruncatedText)
    }

    @Test("Un texte court déposé n'est pas signalé")
    func shortDroppedTextIsNotReported() {
        let plan = DropPlan(items: [.text("une question"), .webURL(URL(string: "https://exemple.fr")!)])
        #expect(plan.draftTexts == ["une question", "https://exemple.fr"])
        #expect(!plan.hasTruncatedText)
    }

    @Test("Un seul signalement, même si plusieurs textes sont coupés")
    func severalTruncatedTextsGiveOneReport() {
        let long = String(repeating: "b", count: limit + 1)
        let plan = DropPlan(items: [.text(long), .text(long)])
        #expect(plan.hasTruncatedText)
        #expect(plan.draftTexts.count == 2)
    }

    @Test("Le filtre du collage ne garde que fichiers, images et refus : le texte appartient au champ")
    func pasteFilterLeavesTextToTheField() {
        let file = URL(fileURLWithPath: "/dépôts/a.pdf")
        let image = URL(fileURLWithPath: "/dépôts/b.png")
        let items: [DroppedItem] = [
            .text("du texte"), .webURL(URL(string: "https://exemple.fr")!),
            .attachment(file), .image(image), .refused(.unsupportedType),
        ]
        #expect(DropPlan.attachableOnly(items) == [.attachment(file), .image(image), .refused(.unsupportedType)])
        #expect(DropPlan.attachableOnly([.text("seul")]).isEmpty)
    }
}

@MainActor
@Suite("Dépôt et collage — application au contrôleur")
struct ControllerReceiveTests {
    private func makeController() -> FileAttachmentController {
        FileAttachmentController(store: AttachmentStore())
    }

    @Test("Du texte déposé va au brouillon, rien n'est joint")
    func textGoesToDraft() {
        let controller = makeController()
        var draft = "Que penses-tu de"
        controller.receive([.text("la tour Eiffel ?")], draft: &draft)
        #expect(draft == "Que penses-tu de la tour Eiffel ?")
        #expect(controller.pendingAttachments.isEmpty)
        #expect(controller.notices.isEmpty)
    }

    @Test("Un texte coupé laisse une note discrète, sans nom de fichier, de style information")
    func truncationLeavesAnInformationNotice() {
        let controller = makeController()
        var draft = ""
        controller.receive([.text(String(repeating: "x", count: ExternalQuerySanitizer.maxLength + 5))], draft: &draft)
        let notice = controller.notices.last
        #expect(notice?.message == FileAttachmentPresentation.truncatedTextMessage(limit: ExternalQuerySanitizer.maxLength))
        #expect(notice?.fileNames.isEmpty == true)
        #expect(notice?.style == .information)
        #expect(draft.count == ExternalQuerySanitizer.maxLength)
    }

    @Test("Un refus reste un avertissement, comme avant")
    func refusalStaysAWarning() {
        let controller = makeController()
        var draft = ""
        controller.receive([.refused(.tooLarge)], draft: &draft)
        #expect(controller.notices.last?.message == DropRefusal.tooLarge.message)
        #expect(controller.notices.last?.style == .warning)
    }

    @Test("Le message de troncature nomme la limite, en français simple")
    func truncationMessage() {
        let message = FileAttachmentPresentation.truncatedTextMessage(limit: 2_000)
        #expect(message.contains("2000"))
        #expect(!message.contains("!"))
    }

    @Test("Le message « rien à coller » est fermé")
    func nothingToPasteMessage() {
        #expect(!FileAttachmentPresentation.nothingToPasteMessage.isEmpty)
    }
}
