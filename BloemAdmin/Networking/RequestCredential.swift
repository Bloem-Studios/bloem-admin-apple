import Foundation

struct RequestIdentity: Sendable, Equatable {
    enum Principal: Sendable, Equatable {
        case administrator
    }

    let serverID: String
    let principal: Principal
    let generation: UInt64
}

struct RequestCredential: Sendable, Equatable {
    let accessToken: String
    let identity: RequestIdentity
}
