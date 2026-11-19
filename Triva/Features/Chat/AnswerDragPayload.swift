//
//  AnswerDragPayload.swift
//  Triva
//
//  Chantier 2.2 (G2) : glisser SORTANT (spec 2.2 §5 « Sortant »). Ce fichier ne contient que la logique
//  pure (testée sans interface) : ce qui part avec le glisser, et où la poignée est proposée.
//  La vue est dans `AnswerDragViews.swift`.
//
//  - Réponse : le texte emporté est EXACTEMENT celui du bouton Copier / Partager (`AnswerShareText.text`,
//    donc avec la mention « Réponse générée par IA avec Triva », règle V1). Aucune seconde construction du
//    texte : la poignée reçoit la chaîne déjà marquée et REFUSE de partir si elle ne porte pas la mention.
//    Comme Partager, le glisser ne porte que le texte marqué (pas la métadonnée machine du presse-papiers,
//    qui exigerait un type déclaré dans Info.plist : hors périmètre).
//  - Source web : l'adresse (http/https) seulement. Une pièce jointe n'a rien à emporter : le fichier est
//    à l'utilisateur, il l'a déjà.
//

import Foundation

nonisolated enum AnswerDragPayload {
    // À valider par Ben : libellé VoiceOver / infobulle de la poignée.
    static let handleTitle = "Glisser la réponse vers une autre app"
    static let handleSystemImage = "hand.draw"

    /// Longueur maximale de l'extrait montré sous le doigt ou le pointeur pendant le glisser.
    static let previewLimit = 160

    /// Le texte à emporter, ou `nil` s'il ne porte pas la mention « générée par IA » : rien ne quitte l'app
    /// sans marquage (`AIGeneratedMarking`), même si un appelant se trompait de chaîne.
    static func text(fromShareText shareText: String) -> String? {
        let trimmed = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(AIGeneratedMarking.footer) else { return nil }
        return shareText
    }

    /// Début de la réponse, sans la mention ni la liste des sources, pour l'image qui suit le pointeur.
    static func previewExcerpt(of shareText: String) -> String {
        var text = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(AIGeneratedMarking.footer) {
            text = String(text.dropLast(AIGeneratedMarking.footer.count))
        }
        // Une seule ligne de lecture : on s'arrête au premier saut de ligne vide (TL;DR ou premier paragraphe).
        let firstBlock = text.components(separatedBy: "\n\n").first ?? text
        let flat = firstBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > previewLimit else { return flat }
        return String(flat.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Sur iPhone, glisser vers une autre app n'existe pas (pas de Split View) : pas de poignée.
    /// Mac et iPad : oui.
    static func offersHandle(isPhone: Bool) -> Bool { !isPhone }
}

nonisolated enum SourceDragPayload {
    /// L'adresse à emporter pour une ligne de la liste des sources : la même règle que le lien de la ligne
    /// (`SourcesListPresentation.openableURL` : http et https seulement). `nil` pour une pièce jointe
    /// (URL synthétique `triva-attachment:`), une URL sans hôte ou hors http(s).
    static func url(for source: SearXNGSearchResult) -> URL? {
        SourcesListPresentation.openableURL(for: source)
    }
}
