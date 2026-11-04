//
//  CloudProviderFailureTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 02/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Statut HTTP d'échec → cause attendue. Bornes de la plage 5xx comprises
/// (500 et 599) : toute la plage est une panne ; le reste, un refus qui garde
/// son code. Constante de fichier non isolée : `CloudProviderFailure` est
/// `nonisolated`, et le target de tests n'a pas l'isolation `MainActor` par
/// défaut de l'app.
private let statusClassification: [(Int, CloudProviderFailure)] = [
    (401, .apiKeyRejected(statusCode: 401)),
    (403, .apiKeyRejected(statusCode: 403)),
    (413, .contextWindowExceeded),
    (402, .rateLimited),
    (429, .rateLimited),
    (500, .serverUnavailable(statusCode: 500)),
    (502, .serverUnavailable(statusCode: 502)),
    (503, .serverUnavailable(statusCode: 503)),
    (599, .serverUnavailable(statusCode: 599)),
    (400, .requestRejected(statusCode: 400)),
    (404, .requestRejected(statusCode: 404)),
    (422, .requestRejected(statusCode: 422)),
    (600, .requestRejected(statusCode: 600)),
]

/// Un représentant de chacun des six cas.
private let oneOfEachFailure: [CloudProviderFailure] = [
    .apiKeyRejected(statusCode: nil),
    .rateLimited,
    .contextWindowExceeded,
    .serverUnavailable(statusCode: 503),
    .unreachable,
    .requestRejected(statusCode: 404),
]

/// Pure donnée `nonisolated` : suite non isolée, exécutée en parallèle.
@Suite("CloudProviderFailure (bug 6)")
struct CloudProviderFailureTests {
    @Test("402, crédit épuisé : le message renvoie vers le crédit du compte, pas vers le modèle")
    func paymentRequiredPointsToTheAccountCredit() {
        let message = CloudProviderFailure(statusCode: 402).userFacingMessage(provider: "OpenRouter")
        #expect(message.contains("vérifie le crédit de ton compte OpenRouter"))
        #expect(!message.contains("modèle"))
    }

    @Test("init(statusCode:) classe chaque statut d'échec", arguments: statusClassification)
    func classifiesFailureStatus(statusCode: Int, expected: CloudProviderFailure) {
        #expect(CloudProviderFailure(statusCode: statusCode) == expected)
    }

    @Test("Chaque message nomme le fournisseur des Réglages", arguments: oneOfEachFailure)
    func messageNamesTheProvider(failure: CloudProviderFailure) {
        let message = failure.userFacingMessage(provider: "Mon LLM")
        #expect(message.contains("Mon LLM"))
    }

    @Test("Six causes, six messages distincts")
    func messagesAreDistinct() {
        let messages = oneOfEachFailure.map { $0.userFacingMessage(provider: "Groq") }
        #expect(Set(messages).count == oneOfEachFailure.count)
    }

    @Test("Chaque message dit quoi faire : réessayer, ou aller voir les Réglages ou la connexion", arguments: oneOfEachFailure)
    func messageIsActionable(failure: CloudProviderFailure) {
        let message = failure.userFacingMessage(provider: "Groq")
        let hints = ["Réessaie", "réessaie", "Réglages"]
        #expect(hints.contains { message.contains($0) }, "Message sans action proposée : \(message)")
    }

    @Test("Clé refusée : même message, statut connu ou non")
    func apiKeyMessageIgnoresStatus() {
        let withStatus = CloudProviderFailure.apiKeyRejected(statusCode: 403).userFacingMessage(provider: "OpenAI")
        let withoutStatus = CloudProviderFailure.apiKeyRejected(statusCode: nil).userFacingMessage(provider: "OpenAI")
        #expect(withStatus == withoutStatus)
        #expect(withStatus == "Clé API refusée par OpenAI. Vérifie-la dans les Réglages.")
    }

    @Test("Requête refusée : le statut, sans risque, aide au diagnostic")
    func requestRejectedShowsItsStatus() {
        let message = CloudProviderFailure.requestRejected(statusCode: 422).userFacingMessage(provider: "Mistral")
        #expect(message == "Mistral a refusé la requête (erreur 422). Vérifie le modèle choisi dans les Réglages.")
    }

    @Test("isCancellation : tâche Swift annulée ou requête URLSession annulée, rien d'autre")
    func recognizesOnlyCancellation() {
        #expect(CloudProviderFailure.isCancellation(CancellationError()))
        #expect(CloudProviderFailure.isCancellation(URLError(.cancelled)))
        #expect(!CloudProviderFailure.isCancellation(URLError(.timedOut)))
        #expect(!CloudProviderFailure.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!CloudProviderFailure.isCancellation(CocoaError(.userCancelled)))
    }
}
