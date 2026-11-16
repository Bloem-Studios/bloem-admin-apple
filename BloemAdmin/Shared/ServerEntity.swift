import AppIntents
import Foundation

/// A saved server as Shortcuts, widget settings and the Control Center control offer it. The list comes
/// from the snapshot the app writes (names and ids only); nothing here reads a sign-in.
struct ServerEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ServerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        Self.allServers().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        Self.allServers()
    }

    static func allServers() -> [ServerEntity] {
        (FileSnapshotStore.appGroup()?.load()?.servers ?? []).map { ServerEntity(id: $0.id, name: $0.name) }
    }
}
