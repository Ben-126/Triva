//
//  WidgetExecutor.swift
//  Triva
//
//  Created by ben podrojsky on 17/09/2026.
//

import Foundation

/// Trace structurée d'un widget qui n'a pas abouti. AJOUT vis-à-vis de la version web d'origine :
/// elle se contente d'un `console.error` et perd l'information. Ici
/// l'échec remonte dans le résultat, ce qui le rend testable et exploitable
/// (un widget météo qui échoue systématiquement doit pouvoir se constater
/// autrement qu'en lisant une console).
///
/// L'erreur d'origine est DÉLIBÉRÉMENT absente : un widget appelle le
/// provider IA actif, qui peut être un fournisseur cloud BYOK. Un serveur
/// malveillant (ou simplement bavard) peut renvoyer la clé API de
/// l'utilisateur dans le corps de son erreur — piège déjà traité dans
/// `ChatViewModel.userFacingMessage(for:)`. Ne transporter qu'un motif fermé
/// rend la fuite impossible par construction, plutôt que de compter sur
/// chaque futur appelant pour ne jamais afficher ce champ.
nonisolated struct SearchWidgetFailure: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// Le widget a levé une erreur (réseau, statut HTTP, décodage d'une
        /// API au schéma pourtant connu). Voir la règle `nil` contre `throw`
        /// de `SearchWidget`.
        case threw
        /// Le budget de temps global a été atteint avant que ce widget ne
        /// rende sa réponse.
        case timedOut
    }

    let kind: SearchWidgetKind
    let reason: Reason
}

/// Résultat complet d'un tour d'exécution : ce qui a abouti, et ce qui a
/// échoué. Les deux listes suivent l'ordre d'injection des widgets dans
/// `WidgetExecutor`, pas l'ordre d'arrivée des réponses — sans quoi l'ordre
/// d'affichage changerait d'une requête à l'autre au gré de la latence
/// réseau.
nonisolated struct WidgetExecutionReport: Sendable {
    let outputs: [SearchWidgetOutput]
    let failures: [SearchWidgetFailure]

    static let empty = WidgetExecutionReport(outputs: [], failures: [])

    /// Bloc de contexte prêt à être concaténé au prompt de rédaction.
    /// Les contextes vides sont ignorés : un widget peut n'avoir qu'une
    /// donnée à afficher sans rien d'utile à dire au modèle, et une ligne
    /// vide au milieu d'un prompt ne fait que diluer l'attention d'un petit
    /// modèle on-device.
    var combinedLLMContext: String {
        outputs
            .map(\.llmContext)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Port de l'exécuteur de widgets de la version web d'origine : sélectionne
/// les widgets éligibles à partir de la classification (1.1) et les exécute
/// tous EN PARALLÈLE, sans jamais échouer globalement.
///
/// DIVERGENCE structurelle assumée vis-à-vis de la version web d'origine : l'exécuteur est une
/// classe statique avec un registre global (`static widgets = new Map`)
/// alimenté par les effets de bord d'un `import`. Ici les
/// widgets sont INJECTÉS au constructeur, comme tout le reste du projet
/// (`SearXNGSearching`, `ScrapeServing`, `AIGenerating`) : un état statique
/// global rend l'ordre d'exécution des tests dépendant de qui a importé quoi,
/// et empêche d'exécuter deux jeux de widgets différents. L'assemblage réel
/// (quels widgets concrets sont branchés) appartient donc à l'appelant, pas
/// à ce fichier — c'est aussi ce qui permet d'écrire et de tester l'exécuteur
/// sans dépendre des services météo et calcul.
///
/// Sur l'exclusion du widget bourse, voir `SearchWidgetKind` : elle est
/// garantie par le type (aucun `case stock` n'existe), l'exécuteur n'a donc
/// aucun filtre spécial à appliquer.
/// `nonisolated` : c'est un orchestrateur pur (un `TaskGroup` et une minuterie),
/// sans aucun état d'interface. Sans ce marqueur il hériterait de `@MainActor`
/// sous `-default-isolation=MainActor`, et comme son appelant réel
/// (`ChatViewModel`) est lui-même `@MainActor`, TOUT le travail des widgets —
/// requête réseau météo, évaluation d'expression — s'exécuterait sur le thread
/// principal. Ce n'est donc pas un ajustement de compilation mais une
/// correction de fond : l'exécution des widgets sort du main actor.
nonisolated struct WidgetExecutor: Sendable {
    /// Budget de temps TOTAL de l'étape widgets, tous widgets confondus.
    ///
    /// Justification de la valeur : le chemin critique d'un widget est une
    /// génération LLM courte (extraction d'un lieu ou d'une expression, une
    /// quarantaine de tokens — plusieurs secondes sur un MLX 0,5B on-device)
    /// suivie d'au plus deux requêtes HTTP successives (les deux endpoints
    /// appelés par `WeatherWidgetService` : `geocoding-api.open-meteo.com`
    /// puis `api.open-meteo.com`). Aucune de ces durées n'a été mesurée sur
    /// appareil : 12 s est une borne volontairement généreuse, choisie pour
    /// ne jamais couper un chemin nominal même sur matériel lent, PAS pour
    /// coller au plus près d'une latence connue.
    ///
    /// 12 s est aussi DÉLIBÉRÉMENT inférieur aux 30 s de timeout par défaut
    /// de `OpenAICompatibleClient` (vérifié : `timeoutInterval: TimeInterval = 30`
    /// dans son `init`) : une extraction confiée à un fournisseur
    /// cloud lent sera coupée ici avant d'avoir épuisé son propre délai.
    /// C'est l'arbitrage voulu, pas un oubli — passé 12 s d'attente, la
    /// réponse rédigée vaut mieux pour l'utilisateur qu'un widget de plus.
    static let defaultTotalTimeout: Duration = .seconds(12)

    private let widgets: [any SearchWidget]
    private let totalTimeout: Duration

    init(widgets: [any SearchWidget], totalTimeout: Duration = WidgetExecutor.defaultTotalTimeout) {
        self.widgets = widgets
        self.totalTimeout = totalTimeout
    }

    /// N'échoue JAMAIS et ne `throw` jamais : un widget est un bonus
    /// d'affichage, son échec ne doit en aucun cas faire tomber la réponse
    /// principale (même principe que `ScrapeService.scrape(url:)`).
    ///
    /// `shouldExecute` est évalué AVANT de créer la moindre tâche : quand
    /// aucun widget n'est concerné — le cas courant, la grande majorité des
    /// requêtes — la fonction retourne immédiatement sans même armer la
    /// minuterie du budget de temps.
    func execute(_ input: SearchWidgetInput) async -> WidgetExecutionReport {
        let eligible = widgets.filter { $0.shouldExecute(for: input.classification) }
        guard !eligible.isEmpty else { return .empty }
        return await Self.runInParallel(eligible, input: input, totalTimeout: totalTimeout)
    }

    /// Résultat d'une tâche du groupe. L'index (position dans `eligible`)
    /// plutôt que le `kind` sert d'identifiant : il reste correct même si
    /// deux widgets de même `kind` étaient injectés par erreur, et il donne
    /// gratuitement l'ordre d'affichage déterministe.
    private enum WidgetTaskResult: Sendable {
        case produced(index: Int, output: SearchWidgetOutput?)
        case failed(index: Int)
        case deadlineReached
    }

    /// Un `TaskGroup` avec une tâche « minuterie » en plus des widgets : dès
    /// qu'un résultat quelconque laisse `pending` vide, on sort. C'est le
    /// même chemin de sortie pour les deux fins possibles (tous les widgets
    /// ont répondu, ou le délai est atteint), donc impossible d'oublier le
    /// `cancelAll()` sur l'une des deux — et cet oubli serait coûteux : la
    /// sortie d'un `withTaskGroup` attend implicitement ses tâches
    /// restantes, on attendrait donc soit la minuterie entière après le
    /// dernier widget, soit un widget bloqué après le dépassement du délai.
    private static func runInParallel(
        _ eligible: [any SearchWidget],
        input: SearchWidgetInput,
        totalTimeout: Duration
    ) async -> WidgetExecutionReport {
        await withTaskGroup(of: WidgetTaskResult.self) { group in
            for (index, widget) in eligible.enumerated() {
                group.addTask {
                    do {
                        let output = try await widget.execute(input)
                        return .produced(index: index, output: output)
                    } catch {
                        // Toute erreur est absorbée ici : c'est la promesse
                        // « un widget qui throw est ignoré ». L'erreur elle-même
                        // n'est pas conservée, voir `SearchWidgetFailure`.
                        //
                        // Y compris `CancellationError` quand l'appelant annule
                        // le tour (l'utilisateur arrête la génération) : le
                        // rapport portera alors un `.threw` qui n'est pas une
                        // vraie panne. Assumé — ce rapport n'est jamais affiché
                        // à l'utilisateur, et distinguer les deux demanderait de
                        // faire confiance au widget pour propager fidèlement
                        // l'annulation, ce que le contrat ne peut pas garantir.
                        return .failed(index: index)
                    }
                }
            }

            group.addTask {
                // `try?` : l'annulation de cette minuterie (cas nominal, quand
                // tous les widgets ont fini avant le délai) n'est pas un échec.
                // La valeur renvoyée est alors ignorée, la boucle est déjà sortie.
                try? await Task.sleep(for: totalTimeout)
                return .deadlineReached
            }

            var outputsByIndex = [SearchWidgetOutput?](repeating: nil, count: eligible.count)
            var reasonsByIndex = [SearchWidgetFailure.Reason?](repeating: nil, count: eligible.count)
            var pending = Set(eligible.indices)

            // `while let ... = await group.next()` plutôt que `for await ... in
            // group` : la boucle appelle `group.cancelAll()` sur son propre
            // groupe, ce qui est plus clair (et sans ambiguïté d'accès
            // exclusif) avec une consommation explicitement mutante.
            while let result = await group.next() {
                switch result {
                case .deadlineReached:
                    for index in pending {
                        reasonsByIndex[index] = .timedOut
                    }
                    pending.removeAll()
                case .produced(let index, let output):
                    // `output == nil` n'est pas un échec : le widget a décidé
                    // qu'il n'avait rien à afficher (voir `SearchWidget`).
                    outputsByIndex[index] = output
                    pending.remove(index)
                case .failed(let index):
                    reasonsByIndex[index] = .threw
                    pending.remove(index)
                }

                if pending.isEmpty {
                    group.cancelAll()
                    break
                }
            }

            return makeReport(eligible: eligible, outputsByIndex: outputsByIndex, reasonsByIndex: reasonsByIndex)
        }
    }

    /// Reconstruit les deux listes dans l'ordre d'injection. Fonction pure,
    /// isolée pour garder la boucle du groupe lisible.
    private static func makeReport(
        eligible: [any SearchWidget],
        outputsByIndex: [SearchWidgetOutput?],
        reasonsByIndex: [SearchWidgetFailure.Reason?]
    ) -> WidgetExecutionReport {
        var outputs: [SearchWidgetOutput] = []
        var failures: [SearchWidgetFailure] = []

        for index in eligible.indices {
            if let output = outputsByIndex[index] {
                outputs.append(output)
            }
            if let reason = reasonsByIndex[index] {
                failures.append(SearchWidgetFailure(kind: eligible[index].kind, reason: reason))
            }
        }

        return WidgetExecutionReport(outputs: outputs, failures: failures)
    }
}
