//
//  SearchKeysViewModelTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Écran « Clés de recherche » (RI2), sans vue, sans réseau et sans le vrai trousseau : faux
// `APIKeyStoring`, et test de clé factice ou vrai provider sur un faux transport.

/// Trousseau en mémoire, avec ses pannes et le compte de ses lectures.
private final class FakeSearchKeychain: APIKeyStoring, @unchecked Sendable {
    var items: [String: String] = [:]
    var failOnRead = false
    var failOnSave = false
    var failOnDelete = false
    private(set) var readCount = 0

    func apiKey(account: String) throws -> String? {
        readCount += 1
        if failOnRead { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        return items[account]
    }

    func save(apiKey: String, account: String) throws {
        if failOnSave { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        items[account] = apiKey
    }

    func deleteAPIKey(account: String) throws {
        if failOnDelete { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        items[account] = nil
    }
}

/// Une erreur hors contrat dont le texte cite la clé : le pire cas pour un message affiché.
private struct KeyLeakingError: Error, CustomStringConvertible {
    let key: String
    var description: String { "refus de \(key)" }
}

/// Test de clé scénarisé. Journalise les clés reçues : c'est lui qui prouve qu'un test a eu lieu.
@MainActor
private final class ValidatorScript {
    var result: Result<SearchKeyValidationOutcome, any Error> = .success(.valid)
    private(set) var testedKeys: [String] = []

    func make(_ credentials: SearchKeyCredentials) -> any SearchKeyValidating {
        testedKeys.append(credentials.apiKey.value)
        return ResultValidator(result: result)
    }
}

private struct ResultValidator: SearchKeyValidating {
    let result: Result<SearchKeyValidationOutcome, any Error>

    func validateKey() async throws -> SearchKeyValidationOutcome {
        try result.get()
    }
}

/// Test qui reste en suspens jusqu'à `open()`, pour observer l'état PENDANT un test.
private actor ValidationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}

private struct GatedValidator: SearchKeyValidating {
    let gate: ValidationGate

    func validateKey() async throws -> SearchKeyValidationOutcome {
        await gate.wait()
        return .valid
    }
}

@MainActor
@Suite("SearchKeysViewModel — clés de recherche personnelles")
struct SearchKeysViewModelTests {
    private let keychain = FakeSearchKeychain()
    private let script = ValidatorScript()

    private func makeViewModel() -> SearchKeysViewModel {
        SearchKeysViewModel(
            store: SearchKeyStore(keyStore: keychain, requester: ChainOfflineRequester()),
            makeValidator: { [script] in script.make($0) }
        )
    }

    private func store(_ key: String, for source: BYOKSearchSource) {
        keychain.items[source.keyAccount] = key
    }

    // MARK: Lecture

    /// Le piège de `BYOKProvidersView` : l'expression qui construit le modèle est réévaluée à chaque
    /// rendu du parent, une lecture du trousseau y serait refaite à chaque fois.
    @Test("L'init ne lit pas le trousseau et ne teste rien")
    func initHasNoSideEffect() {
        store("cle", for: .brave)

        let viewModel = makeViewModel()

        #expect(keychain.readCount == 0)
        #expect(script.testedKeys.isEmpty)
        #expect(viewModel.entry(for: .brave) == SearchKeyEntry())
    }

    @Test("Aucune clé : champ de saisie pour chaque source, aucun message")
    func reloadWithoutKeys() {
        let viewModel = makeViewModel()

        viewModel.reload()

        for source in BYOKSearchSource.allCases {
            #expect(viewModel.entry(for: source) == SearchKeyEntry())
        }
    }

    /// Chaque test consomme une requête du quota de l'utilisateur.
    @Test("Une clé enregistrée est vue comme telle, sans aucun test à l'apparition")
    func reloadSeesStoredKeysWithoutTestingThem() {
        store("cle", for: .tavily)
        let viewModel = makeViewModel()

        viewModel.reload()

        #expect(viewModel.entry(for: .tavily).hasStoredKey)
        #expect(!viewModel.entry(for: .brave).hasStoredKey)
        #expect(script.testedKeys.isEmpty)
    }

    @Test("Une clé ajoutée ou supprimée dans une autre fenêtre s'affiche à la relecture, sans ancien message")
    func reloadFollowsChangesMadeElsewhere() async {
        store("cle", for: .brave)
        let viewModel = makeViewModel()
        viewModel.reload()
        await viewModel.testStoredKey(for: .brave)
        #expect(viewModel.entry(for: .brave).feedback == .valid)

        keychain.items[BYOKSearchSource.brave.keyAccount] = nil
        viewModel.reload()

        #expect(viewModel.entry(for: .brave) == SearchKeyEntry())
    }

    @Test("Trousseau illisible : l'écran le dit, et la lecture réussie suivante efface le message")
    func unreadableKeychainIsReportedThenCleared() {
        store("cle", for: .brave)
        keychain.failOnRead = true
        let viewModel = makeViewModel()

        viewModel.reload()

        #expect(!viewModel.entry(for: .brave).hasStoredKey)
        #expect(viewModel.entry(for: .brave).feedback == .storage(.keychainFailure))

        keychain.failOnRead = false
        viewModel.reload()

        #expect(viewModel.entry(for: .brave).hasStoredKey)
        #expect(viewModel.entry(for: .brave).feedback == nil)
    }

    // MARK: Tester et enregistrer

    @Test("Clé valide : testée puis enregistrée, sans les espaces du collage")
    func validKeyIsSavedTrimmed() async {
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "  cle-brave\n", for: .brave)

        #expect(script.testedKeys == ["cle-brave"])
        #expect(keychain.items[BYOKSearchSource.brave.keyAccount] == "cle-brave")
        let entry = viewModel.entry(for: .brave)
        #expect(entry.hasStoredKey)
        #expect(!entry.isTesting)
        #expect(entry.feedback == .valid)
    }

    /// `SearchKeyValidationOutcome.validQuotaReached` : une clé inconnue n'a pas de quota.
    @Test("Quota atteint : la clé est reconnue, donc enregistrée, et présentée comme valide")
    func quotaReachedKeyIsSavedAndNotShownAsARefusal() async {
        script.result = .success(.validQuotaReached)
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "cle", for: .tavily)

        #expect(keychain.items[BYOKSearchSource.tavily.keyAccount] == "cle")
        let feedback = viewModel.entry(for: .tavily).feedback
        #expect(feedback == .validQuotaReached)
        #expect(feedback?.isPositive == true)
        #expect(feedback?.message.contains("quota") == true)
        #expect(feedback?.message.contains("valide") == true)
    }

    @Test("Test en échec : RIEN n'est enregistré, l'écran dit pourquoi", arguments: [
        WebSearchError.unauthorized, .unavailable, .timeout, .invalidResponse,
    ])
    func failedTestSavesNothing(error: WebSearchError) async {
        script.result = .failure(error)
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "cle", for: .brave)

        #expect(keychain.items.isEmpty)
        let entry = viewModel.entry(for: .brave)
        #expect(!entry.hasStoredKey)
        #expect(!entry.isTesting)
        #expect(entry.feedback == .draftRejected(error))
        #expect(entry.feedback?.isPositive == false)
        #expect(entry.feedback?.message.contains(error.userFacingMessage) == true)
        #expect(entry.feedback?.message.contains("n'a pas été enregistrée") == true)
    }

    @Test("Annulation : ni message, ni enregistrement, ce n'est ni un échec ni une validation", arguments: [
        CancellationError() as any Error, URLError(.cancelled) as any Error,
    ])
    func cancelledTestReturnsToNeutral(error: any Error) async {
        script.result = .failure(error)
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "cle", for: .brave)

        #expect(keychain.items.isEmpty)
        #expect(viewModel.entry(for: .brave) == SearchKeyEntry())
    }

    @Test("Saisie vide ou blanche : aucun test, donc aucune requête consommée", arguments: ["", "   \n"])
    func emptyDraftIsNotTested(draft: String) async {
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: draft, for: .brave)

        #expect(script.testedKeys.isEmpty)
        #expect(keychain.items.isEmpty)
        #expect(viewModel.entry(for: .brave).feedback == .storage(.emptyKey))
    }

    @Test("Clé valide mais trousseau en panne : l'écran le dit, la clé n'est pas annoncée comme enregistrée")
    func keychainRefusalOnSaveIsReported() async {
        keychain.failOnSave = true
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "cle", for: .brave)

        let entry = viewModel.entry(for: .brave)
        #expect(!entry.hasStoredKey)
        #expect(entry.feedback == .storage(.keychainFailure))
    }

    @Test("Une clé n'affecte que sa source")
    func aKeyOnlyAffectsItsSource() async {
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "cle", for: .brave)

        #expect(viewModel.entry(for: .tavily) == SearchKeyEntry())
        #expect(keychain.items[BYOKSearchSource.tavily.keyAccount] == nil)
    }

    @Test("Pendant un test : état visible, et un second appui ne consomme pas une seconde requête")
    func aTestInProgressIgnoresASecondCall() async throws {
        let gate = ValidationGate()
        var validatorCalls = 0
        let viewModel = SearchKeysViewModel(
            store: SearchKeyStore(keyStore: keychain, requester: ChainOfflineRequester()),
            makeValidator: { _ in
                validatorCalls += 1
                return GatedValidator(gate: gate)
            }
        )

        let first = Task { await viewModel.testAndSave(rawKey: "cle", for: .brave) }
        await ChainFixtures.waitUntil("test en cours") { viewModel.entry(for: .brave).isTesting }

        #expect(viewModel.entry(for: .brave).canSubmit(draft: "cle") == false)
        await viewModel.testAndSave(rawKey: "autre", for: .brave)
        await viewModel.testStoredKey(for: .brave)
        #expect(validatorCalls == 1)

        await gate.open()
        await first.value

        #expect(!viewModel.entry(for: .brave).isTesting)
        #expect(keychain.items[BYOKSearchSource.brave.keyAccount] == "cle")
    }

    // MARK: Avec les vrais providers

    /// Le test bout en bout de la couture : `SearchKeyCredentials.makeProvider` sur un faux
    /// transport, statuts réels de Brave et Tavily.
    @Test("Vrai provider : 401 refuse, 429 prouve que la clé est reconnue, 200 l'accepte", arguments: [
        (BYOKSearchSource.brave, 401, SearchKeyFeedback.draftRejected(.unauthorized), false),
        (.tavily, 401, .draftRejected(.unauthorized), false),
        (.brave, 429, .validQuotaReached, true),
        (.tavily, 432, .validQuotaReached, true),
        (.brave, 500, .draftRejected(.unavailable), false),
        (.brave, 200, .valid, true),
        (.tavily, 200, .valid, true),
    ])
    func realProviders(source: BYOKSearchSource, status: Int, expected: SearchKeyFeedback, isSaved: Bool) async {
        let requester = BYOKTestRequester(status: status, body: #"{"web":{"results":[]},"results":[]}"#)
        let viewModel = SearchKeysViewModel(
            store: SearchKeyStore(keyStore: keychain, requester: requester),
            makeValidator: { $0.makeProvider(requester: requester) }
        )

        await viewModel.testAndSave(rawKey: "cle", for: source)

        #expect(viewModel.entry(for: source).feedback == expected)
        #expect(viewModel.entry(for: source).hasStoredKey == isSaved)
        #expect((keychain.items[source.keyAccount] != nil) == isSaved)
        // Une seule requête : chaque test est décompté du quota de l'utilisateur.
        #expect(requester.requests.count == 1)
    }

    // MARK: Retester

    @Test("Retest de la clé enregistrée : c'est bien elle qui est testée", arguments: [
        SearchKeyValidationOutcome.valid, .validQuotaReached,
    ])
    func storedKeyIsRetested(outcome: SearchKeyValidationOutcome) async {
        store("cle-stockee", for: .brave)
        script.result = .success(outcome)
        let viewModel = makeViewModel()
        viewModel.reload()

        await viewModel.testStoredKey(for: .brave)

        #expect(script.testedKeys == ["cle-stockee"])
        #expect(viewModel.entry(for: .brave).feedback == (outcome == .valid ? .valid : .validQuotaReached))
    }

    /// Certains services ne montrent la clé qu'à sa création : une panne passagère ne doit jamais
    /// l'effacer. Ici, la clé est gardée même refusée : c'est à l'utilisateur de décider.
    @Test("Retest en échec : la clé est GARDÉE, l'écran dit pourquoi", arguments: [
        WebSearchError.unauthorized, .unavailable, .timeout,
    ])
    func failedRetestKeepsTheKey(error: WebSearchError) async {
        store("cle", for: .brave)
        script.result = .failure(error)
        let viewModel = makeViewModel()
        viewModel.reload()

        await viewModel.testStoredKey(for: .brave)

        #expect(keychain.items[BYOKSearchSource.brave.keyAccount] == "cle")
        let entry = viewModel.entry(for: .brave)
        #expect(entry.hasStoredKey)
        #expect(!entry.isTesting)
        #expect(entry.feedback == .storedKeyFailed(error))
        #expect(entry.feedback?.message == error.userFacingMessage)
    }

    @Test("Retest annulé : l'ancien message n'est pas remplacé par un échec")
    func cancelledRetestIsNeutral() async {
        store("cle", for: .brave)
        script.result = .failure(CancellationError())
        let viewModel = makeViewModel()
        viewModel.reload()

        await viewModel.testStoredKey(for: .brave)

        #expect(viewModel.entry(for: .brave).hasStoredKey)
        #expect(viewModel.entry(for: .brave).feedback == nil)
    }

    @Test("Retest d'une clé disparue entre-temps : retour au champ de saisie, aucun test lancé")
    func retestOfAKeyDeletedElsewhere() async {
        store("cle", for: .brave)
        let viewModel = makeViewModel()
        viewModel.reload()
        keychain.items[BYOKSearchSource.brave.keyAccount] = nil

        await viewModel.testStoredKey(for: .brave)

        #expect(viewModel.entry(for: .brave) == SearchKeyEntry())
        #expect(script.testedKeys.isEmpty)
    }

    @Test("Retest avec un trousseau illisible : l'écran le dit, la clé reste affichée")
    func retestWithAnUnreadableKeychain() async {
        store("cle", for: .brave)
        let viewModel = makeViewModel()
        viewModel.reload()
        keychain.failOnRead = true

        await viewModel.testStoredKey(for: .brave)

        #expect(viewModel.entry(for: .brave).hasStoredKey)
        #expect(viewModel.entry(for: .brave).feedback == .storage(.keychainFailure))
        #expect(script.testedKeys.isEmpty)
    }

    // MARK: Supprimer

    @Test("Suppression : la clé de CETTE source seulement, et plus aucun message")
    func deletingRemovesOnlyThatKey() async {
        store("b", for: .brave)
        store("t", for: .tavily)
        let viewModel = makeViewModel()
        viewModel.reload()
        await viewModel.testStoredKey(for: .brave)

        viewModel.deleteKey(for: .brave)

        #expect(keychain.items[BYOKSearchSource.brave.keyAccount] == nil)
        #expect(keychain.items[BYOKSearchSource.tavily.keyAccount] == "t")
        #expect(viewModel.entry(for: .brave) == SearchKeyEntry())
        #expect(viewModel.entry(for: .tavily).hasStoredKey)
    }

    /// Écart assumé avec `APIKeysViewModel`, dont le `try?` annonce « supprimée » une clé restée en place.
    @Test("Suppression refusée par le trousseau : la clé reste affichée, et l'écran le dit")
    func keychainRefusalOnDeleteIsReported() {
        store("cle", for: .brave)
        keychain.failOnDelete = true
        let viewModel = makeViewModel()
        viewModel.reload()

        viewModel.deleteKey(for: .brave)

        #expect(viewModel.entry(for: .brave).hasStoredKey)
        #expect(viewModel.entry(for: .brave).feedback == .storage(.keychainFailure))
    }

    @Test("Après une suppression, une nouvelle clé peut être testée et enregistrée")
    func aKeyCanBeReplacedAfterDeletion() async {
        store("ancienne", for: .brave)
        let viewModel = makeViewModel()
        viewModel.reload()

        viewModel.deleteKey(for: .brave)
        await viewModel.testAndSave(rawKey: "nouvelle", for: .brave)

        #expect(keychain.items[BYOKSearchSource.brave.keyAccount] == "nouvelle")
        #expect(viewModel.entry(for: .brave).hasStoredKey)
    }

    // MARK: Secrets

    /// Règle absolue du projet : un serveur malveillant pourrait renvoyer la clé dans son erreur.
    @Test("La clé n'apparaît jamais dans un état affichable, même si l'erreur la cite")
    func theKeyNeverReachesWhatIsDisplayed() async {
        let secret = "sk-secret-12345"
        let leakingError = KeyLeakingError(key: secret)
        let scenarios: [Result<SearchKeyValidationOutcome, any Error>] = [
            .success(.valid),
            .success(.validQuotaReached),
            .failure(WebSearchError.unauthorized),
            .failure(leakingError),
        ]
        for scenario in scenarios {
            script.result = scenario
            keychain.items = [:]
            let viewModel = makeViewModel()

            await viewModel.testAndSave(rawKey: secret, for: .brave)

            let entry = viewModel.entry(for: .brave)
            #expect(entry.feedback?.message.contains(secret) == false)
            #expect(!String(describing: entry).contains(secret))
            #expect(!String(reflecting: entry).contains(secret))
        }
    }

    @Test("Une erreur hors contrat vaut « le service ne répond pas », jamais son texte")
    func anUnknownErrorNeverShowsItsText() async {
        script.result = .failure(KeyLeakingError(key: "sk-secret"))
        let viewModel = makeViewModel()

        await viewModel.testAndSave(rawKey: "sk-secret", for: .brave)

        #expect(viewModel.entry(for: .brave).feedback == .draftRejected(.unavailable))
        #expect(keychain.items.isEmpty)
    }

    // MARK: Présentation

    @Test("Bouton « Tester et enregistrer » : une vraie saisie, hors test en cours", arguments: [
        ("cle", false, true),
        ("  cle  ", false, true),
        ("", false, false),
        ("   \n", false, false),
        ("cle", true, false),
    ])
    func canSubmit(draft: String, isTesting: Bool, expected: Bool) {
        let entry = SearchKeyEntry(isTesting: isTesting)
        #expect(entry.canSubmit(draft: draft) == expected)
    }

    @Test("Seuls les résultats valides sont positifs")
    func feedbackPolarity() {
        #expect(SearchKeyFeedback.valid.isPositive)
        #expect(SearchKeyFeedback.validQuotaReached.isPositive)
        #expect(!SearchKeyFeedback.draftRejected(.unauthorized).isPositive)
        #expect(!SearchKeyFeedback.storedKeyFailed(.timeout).isPositive)
        #expect(!SearchKeyFeedback.storage(.keychainFailure).isPositive)
    }

    @Test("Chaque source a sa page d'obtention de clé, en https, chez le bon service")
    func keyPages() throws {
        let brave = try #require(BYOKSearchSource.brave.keyPageURL)
        let tavily = try #require(BYOKSearchSource.tavily.keyPageURL)
        #expect(brave.scheme == "https")
        #expect(brave.host()?.hasSuffix("search.brave.com") == true)
        #expect(tavily.scheme == "https")
        #expect(tavily.host() == "app.tavily.com")
        for source in BYOKSearchSource.allCases {
            #expect(source.keyPageURL != nil)
        }
    }
}
