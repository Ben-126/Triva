//
//  TrivaAnswerEntity.swift
//  Triva
//
//  Chantier 2.1 (mission B) : la réponse que « Poser une question à Triva » rend à Raccourcis. Une entité
//  transitoire : elle n'est stockée nulle part, la conversation, elle, est dans l'historique de l'app.
//

import AppIntents
import Foundation

struct TrivaAnswerEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Réponse de Triva")
    }

    @Property(title: "Question")
    var question: String

    @Property(title: "Réponse")
    var text: String

    @Property(title: "Titres des sources")
    var sourceTitles: [String]

    @Property(title: "Liens des sources")
    var sourceLinks: [URL]

    init() {
        question = ""
        text = ""
        sourceTitles = []
        sourceLinks = []
    }

    init(_ answer: HeadlessAnswer) {
        question = answer.question
        text = answer.text
        sourceTitles = answer.sourceTitles
        sourceLinks = answer.sourceLinks
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: question),
            subtitle: LocalizedStringResource(stringLiteral: AnswerPlainText.excerpt(of: text, limit: 80))
        )
    }
}
