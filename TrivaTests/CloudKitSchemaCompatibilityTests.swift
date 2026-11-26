//
//  CloudKitSchemaCompatibilityTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import CoreData
import Foundation
import SwiftData
import Testing
@testable import Triva

// Chantier 2.3, mission K1 : le modèle SwiftData doit rester utilisable par CloudKit le jour où la
// synchronisation sera branchée (compte Apple payant). Règles : doc SwiftData « Syncing model data
// across a person's devices » et doc Core Data « Creating a Core Data Model for CloudKit » :
// aucune contrainte d'unicité, toutes les relations OPTIONNELLES et avec un INVERSE, aucune règle de
// suppression `.deny`. Règle d'attribut (optionnel OU valeur par défaut) : absente de la doc, appliquée
// par prudence (coût nul).
//
// La garde lit le modèle que CoreData voit réellement (`NSManagedObjectModel.makeManagedObjectModel(for:)`),
// pas le code Swift : c'est ce que CloudKit examine, et c'est ce qu'un `[T]` non optionnel trahit.

/// Un défaut de compatibilité, lisible dans le message d'échec d'un test.
nonisolated struct CloudKitSchemaViolation: Equatable, CustomStringConvertible {
    let entity: String
    let property: String?
    let problem: String

    var description: String { "\(entity)\(property.map { ".\($0)" } ?? ""): \(problem)" }
}

/// Examine un modèle Core Data et rend tout ce que CloudKit refuserait ou que la prudence interdit.
nonisolated enum CloudKitSchemaInspector {
    static func violations(in model: NSManagedObjectModel) -> [CloudKitSchemaViolation] {
        model.entities.flatMap(violations(in:))
    }

    private static func violations(in entity: NSEntityDescription) -> [CloudKitSchemaViolation] {
        let name = entity.name ?? "?"
        var result: [CloudKitSchemaViolation] = []
        if !entity.uniquenessConstraints.isEmpty {
            result.append(.init(entity: name, property: nil, problem: "contrainte d'unicité"))
        }
        for property in entity.properties {
            let propertyName = property.name
            if let relationship = property as? NSRelationshipDescription {
                if !relationship.isOptional {
                    result.append(.init(entity: name, property: propertyName, problem: "relation non optionnelle"))
                }
                if relationship.inverseRelationship == nil {
                    result.append(.init(entity: name, property: propertyName, problem: "relation sans inverse"))
                }
                if relationship.deleteRule == .denyDeleteRule {
                    result.append(.init(entity: name, property: propertyName, problem: "règle de suppression .deny"))
                }
                if relationship.isOrdered {
                    result.append(.init(entity: name, property: propertyName, problem: "relation ordonnée"))
                }
            } else if let attribute = property as? NSAttributeDescription {
                if !attribute.isOptional && attribute.defaultValue == nil {
                    result.append(.init(entity: name, property: propertyName, problem: "attribut obligatoire sans valeur par défaut"))
                }
                if attribute.attributeType == .undefinedAttributeType || attribute.attributeType == .objectIDAttributeType {
                    result.append(.init(entity: name, property: propertyName, problem: "type d'attribut refusé"))
                }
            }
        }
        return result
    }
}

/// Un modèle volontairement NON compatible (to-many non optionnel, attribut sans défaut) : prouve que la garde mord.
private enum IncompatibleSample {
    @Model
    final class Parent {
        var id: UUID
        @Relationship(deleteRule: .cascade, inverse: \Child.parent)
        var children: [Child]

        init(id: UUID) {
            self.id = id
            self.children = []
        }
    }

    @Model
    final class Child {
        var name: String
        @Relationship(deleteRule: .nullify)
        var parent: Parent?

        init(name: String) { self.name = name }
    }
}

@MainActor
@Suite("Modèle SwiftData : compatible CloudKit")
struct CloudKitSchemaCompatibilityTests {
    private func coreDataModel() throws -> NSManagedObjectModel {
        let schema = Schema(TrivaModelContainer.models)
        return try #require(NSManagedObjectModel.makeManagedObjectModel(for: schema))
    }

    @Test("Les cinq modèles de l'app sont tous dans le modèle examiné")
    func inspectsEveryEntity() throws {
        let names = Set(try coreDataModel().entities.compactMap(\.name))
        #expect(names == [
            "StoredConversation", "StoredMessage", "StoredSource", "StoredFavorite", "StoredFavoriteSource",
        ])
    }

    @Test("Aucun défaut de compatibilité CloudKit dans le modèle de l'app")
    func modelHasNoCloudKitViolation() throws {
        let found = CloudKitSchemaInspector.violations(in: try coreDataModel())
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test("Toutes les relations sont optionnelles, avec inverse, sans règle .deny, non ordonnées")
    func relationshipsFollowTheRules() throws {
        let relationships = try coreDataModel().entities.flatMap { entity in
            entity.properties.compactMap { $0 as? NSRelationshipDescription }
        }
        // 4 paires : conversation <-> messages, message <-> sources, favori <-> sources de favori.
        #expect(relationships.count == 6)
        for relationship in relationships {
            #expect(relationship.isOptional, "\(relationship.name) doit être optionnelle")
            #expect(relationship.inverseRelationship != nil, "\(relationship.name) doit avoir un inverse")
            #expect(relationship.deleteRule != .denyDeleteRule, "\(relationship.name) ne doit pas être .deny")
            #expect(!relationship.isOrdered, "\(relationship.name) ne doit pas être ordonnée")
        }
    }

    @Test("Les règles de suppression d'origine sont conservées (cascade vers le bas, nullify vers le haut)")
    func deleteRulesAreUnchanged() throws {
        let model = try coreDataModel()
        func rule(_ entity: String, _ relationship: String) throws -> NSDeleteRule {
            let description = try #require(model.entitiesByName[entity])
            let found = try #require(description.relationshipsByName[relationship])
            return found.deleteRule
        }
        #expect(try rule("StoredConversation", "messages") == .cascadeDeleteRule)
        #expect(try rule("StoredMessage", "sources") == .cascadeDeleteRule)
        #expect(try rule("StoredFavorite", "sources") == .cascadeDeleteRule)
        #expect(try rule("StoredMessage", "conversation") == .nullifyDeleteRule)
        #expect(try rule("StoredSource", "message") == .nullifyDeleteRule)
        #expect(try rule("StoredFavoriteSource", "favorite") == .nullifyDeleteRule)
    }

    @Test("Aucune contrainte d'unicité sur aucune entité")
    func noUniquenessConstraint() throws {
        for entity in try coreDataModel().entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name ?? "?")")
        }
    }

    @Test("La garde mord : un modèle avec un to-many non optionnel et un attribut sans défaut est refusé")
    func guardDetectsAnIncompatibleModel() throws {
        let schema = Schema([IncompatibleSample.Parent.self, IncompatibleSample.Child.self])
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: schema))
        let problems = CloudKitSchemaInspector.violations(in: model).map(\.problem)
        #expect(problems.contains("relation non optionnelle"))
        #expect(problems.contains("attribut obligatoire sans valeur par défaut"))
    }
}
