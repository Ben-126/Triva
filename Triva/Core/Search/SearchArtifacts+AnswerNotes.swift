//
//  SearchArtifacts+AnswerNotes.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Mention « Réponse sans recherche » (mission A2, décision 3 de Ben) : toute réponse rédigée sans
/// AUCUNE recherche le dit, sobrement, sous la bulle. Mesuré avant (constat Q1) : « Quelle est la
/// hauteur de la tour Eiffel ? » donnait « 330 pieds », sans source et sans que rien ne signale
/// qu'aucune recherche n'avait eu lieu ; la réponse avait l'air d'un résultat de moteur de recherche.
///
/// Sortie du fichier de l'orchestrateur (déjà bien au-delà de 800 lignes) : seul le champ
/// `SearchArtifacts.answeredWithoutSearch` y vit, rempli par `prepareFinalPrompt` avec cette règle.
extension SearchArtifacts {
    /// Faut-il la mention ? Non quand une recherche a eu lieu (web ou fichiers joints : des sources
    /// existent, ou le prompt a dit qu'il n'y en avait pas), quand un widget a répondu (calcul,
    /// météo : la donnée affichée vient d'un service, pas du modèle), ni pour une salutation, où elle
    /// serait du bruit (« Bonjour » n'a jamais demandé de source).
    ///
    /// `question` : le message BRUT de l'utilisateur, jamais la reformulation du classifieur — celle
    /// d'un « Bonjour » devient « Comment puis-je vous aider ? » (éval A2), qui n'est plus une salutation.
    nonisolated static func answersWithoutSearch(question: String, searchPerformed: Bool, widgetCount: Int) -> Bool {
        !searchPerformed && widgetCount == 0 && !SmallTalk.isGreeting(question)
    }

    /// Mention « Réponse sans source lisible » (mission E1a) : une recherche a eu lieu, mais aucune
    /// source n'était lisible (aucun résultat, ou seulement des pages sans extrait ni contenu :
    /// `citableSourceCount == 0`). Le rédacteur répond alors de mémoire, comme sans recherche, et
    /// `answersWithoutSearch` (qui exige `!searchPerformed`) ne le disait pas. Un widget qui a
    /// répondu (calcul, météo) l'écarte, comme pour l'autre mention. Dérivée de champs existants :
    /// rien à décider dans l'orchestrateur. Le mode Fiable n'y arrive jamais (`lacksReliableSources`).
    nonisolated var answeredWithoutReadableSource: Bool {
        searchPerformed && citableSourceCount == 0 && widgets.isEmpty
    }

    /// Les mentions à persister avec la réponse (`ChatHistoryStore.appendAssistantMessage`).
    nonisolated var storedNotes: StoredAnswerNotes {
        StoredAnswerNotes(
            uncitableSourceNumbers: uncitableSourceNumbers,
            answeredWithoutSearch: answeredWithoutSearch,
            answeredOffline: answeredOffline,
            answeredWithoutReadableSource: answeredWithoutReadableSource
        )
    }
}

/// Reconnaissance d'un message de pure politesse : salutation, remerciement, au revoir, « ça va ? ».
/// Déterministe et lexicale, exprès : le classifieur n'a pas de champ « salutation », et ce qu'il
/// renvoie est stochastique.
///
/// Message ENTIER seulement : tous ses mots doivent appartenir au vocabulaire ci-dessous, et il en
/// faut au plus `maxWords`. « Bonjour, quelle est la hauteur de la tour Eiffel ? » n'est donc pas
/// une salutation (c'est une question précédée d'un bonjour), et sa réponse sans recherche porte
/// la mention. Erreur possible, assumée : un message de politesse hors vocabulaire reçoit la mention, qui
/// reste vraie — aucune recherche n'a eu lieu — et, en Fiable, cherche comme une vraie question (sûr).
/// Espagnol minimal (« Hola qué tal », « Buenos días », « Cómo estás », mission C1, K10) : le vocabulaire
/// ne contient aucun mot espagnol qui serait aussi un mot plein d'une vraie question française.
nonisolated enum SmallTalk {
    /// Au-delà, ce n'est plus une formule de politesse mais une phrase.
    static let maxWords = 8

    static func isGreeting(_ message: String) -> Bool {
        let words = normalizedWords(of: message)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        return words.allSatisfy(vocabulary.contains)
    }

    /// Salutation PURE (« Bonjour ! », « Salut Triva », « Merci beaucoup ») : le rédacteur y répond
    /// sans historique ni reformulation (`SearchOrchestrator.prepareFinalPrompt`). Mesuré (mission
    /// A2) : avec l'historique, « Bonjour ! » envoyé après un haïku recevait le haïku recopié (iPad,
    /// iPhone, 2 générations sur 6 au diagnostic Apple Intelligence), et aucune règle de prompt n'y
    /// suffisait (`PromptTemplates.fullConversationPrompt`) ; la reformulation, elle, fuyait dans la
    /// réponse (« La requête peut être reformulée… ») ou ramenait la demande précédente.
    ///
    /// Plus étroite que `isGreeting`, exprès : « Ok », « D'accord », « Super » sont polis mais aussi
    /// des SUITES de conversation (« D'accord » à « Veux-tu plus de détails ? ») qui ont besoin de
    /// l'historique. `isGreeting`, qui décide de la mention, reste inchangée.
    static func isBareSalutation(_ message: String) -> Bool {
        let words = normalizedWords(of: message)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        return words.allSatisfy(salutationVocabulary.contains)
    }

    private static func normalizedWords(of message: String) -> [String] {
        message
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Normalisé comme `vocabulary`. Ni « ok », ni « d'accord », ni « super » (voir `isBareSalutation`).
    private static let salutationVocabulary: Set<String> = Set("""
    bonjour bonsoir salut coucou hello hi hey rebonjour bjr slt merci beaucoup thanks thank you triva tout le monde
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Normalisé (minuscules, sans accents). Formules et mots qui les accompagnent (« tout le monde »,
    /// « à toi », « Triva »), en français et en anglais.
    private static let vocabulary: Set<String> = Set("""
    bonjour bonsoir salut coucou hello hi hey yo hola allo bjr slt cc re rebonjour \
    merci thanks thank thx beaucoup bien super parfait genial top cool ok okay d accord daccord nickel \
    pour ta ton tes reponse reponses aide \
    au revoir plus bientot bye goodbye ciao adieu bonne nuit journee soiree weekend fin \
    ca va vas tu comment et toi vous allez quoi de neuf how are you doing good morning evening night \
    tout le monde tous a the there everyone all triva mon ma cher chere ami amie much very so a la \
    que tal como estas buenos buenas dias tardes noches
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
