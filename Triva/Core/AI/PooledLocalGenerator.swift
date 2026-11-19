//
//  PooledLocalGenerator.swift
//  Triva
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation

/// Ce que reçoit le chat d'une fenêtre MLX (mission M3) : le modèle PARTAGÉ du pool, derrière la
/// file d'attente. Chaque appel (classement de la question, réponse, suggestions) attend son tour,
/// travaille, puis rend le tour sur TOUS les chemins — fin, erreur, Stop.
///
/// Isolation : le compilateur traite ces méthodes comme isolées au main actor (il accepte l'appel
/// synchrone de `pool.endGeneration`, constaté au build du 19/11), comme le reste du chat. Sans
/// coût : la génération elle-même tourne dans l'acteur `MLXProvider`, ici on ne fait que prendre le
/// tour, relayer le texte et rendre le tour.
nonisolated struct PooledLocalGenerator: AIGenerating {
    let model: any PoolableLocalModel
    let pool: MLXProviderPool
    /// La fenêtre (session de recherche) au nom de laquelle on attend.
    let requester: UUID
    /// `false` pour l'essai d'un modèle pas encore choisi (`MLXProviderPool.trialGenerator`) : il passe par
    /// la file mais n'est pas le modèle résident du pool.
    var requiresResidentModel = true

    private static func beginTurn(
        model: any PoolableLocalModel,
        pool: MLXProviderPool,
        requester: UUID,
        requiresResidentModel: Bool
    ) async throws -> LocalModelTurn {
        if requiresResidentModel {
            return try await pool.beginGeneration(with: model, requester: requester)
        }
        return try await pool.beginTrialGeneration(requester: requester)
    }

    func generate(prompt: String) async throws -> String {
        let turn = try await Self.beginTurn(
            model: model, pool: pool, requester: requester, requiresResidentModel: requiresResidentModel
        )
        do {
            let text = try await model.generate(prompt: prompt)
            pool.endGeneration(turn)
            return text
        } catch {
            pool.endGeneration(turn)
            throw error
        }
    }

    /// Le tour est pris dans la tâche du flux, au premier besoin, et rendu quand la génération se
    /// termine — même si personne ne lit plus le flux : son abandon (`onTermination`) annule la
    /// tâche, donc la génération, donc l'attente.
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        let model = model
        let pool = pool
        let requester = requester
        let requiresResidentModel = requiresResidentModel
        return AsyncThrowingStream { continuation in
            let task = Task {
                let turn: LocalModelTurn
                do {
                    turn = try await Self.beginTurn(
                        model: model, pool: pool, requester: requester, requiresResidentModel: requiresResidentModel
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                do {
                    for try await snapshot in model.streamGenerate(prompt: prompt) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                pool.endGeneration(turn)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
