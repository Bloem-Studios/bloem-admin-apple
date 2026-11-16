import Foundation

/// Who a sign-in belongs to, read from the account access token's claims. A registration is tied to the server
/// and the account it came from; when another account signs in to the same server, the phone's device moves to
/// it. Only the account's id and incarnation are read (never shown or sent), and a token that cannot be read
/// gives "", which the registrar treats as "cannot tell".
enum PushAccountKey {
    static func make(accessToken: String?) -> String {
        guard let accessToken else { return "" }
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = decode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return "" }
        let userID: String
        if let number = claims["user_id"] as? Int {
            userID = String(number)
        } else if let text = claims["user_id"] as? String, !text.isEmpty {
            userID = text
        } else {
            return ""
        }
        let incarnation = (claims["account_incarnation_id"] as? String) ?? ""
        return incarnation.isEmpty ? userID : "\(userID)/\(incarnation)"
    }

    private static func decode(_ segment: String) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The real gateway: the saved servers and their sign-ins, through the same `ServerStore` and session the
/// screens use. Registration needs the administrator's own account sign-in; capabilities are public.
@MainActor
final class StorePushGateway: PushServerGateway {
    private let store: ServerStore
    private let sessionState: AdminSessionState

    init(store: ServerStore, sessionState: AdminSessionState) {
        self.store = store
        self.sessionState = sessionState
    }

    func isSignedIn(_ server: AdminServer) -> Bool {
        store.accessToken(for: server.id) != nil
    }

    func accountKey(_ server: AdminServer) -> String {
        PushAccountKey.make(accessToken: store.accessToken(for: server.id))
    }

    func capabilities(_ server: AdminServer, fresh: Bool) async throws -> BloemCapabilities? {
        let client = store.client(for: server)
        guard fresh else { return try await client.bloemCapabilitiesIfBloem() }
        do {
            return try await client.bloemCapabilities()
        } catch let error as APIError where error.statusCode == 404 {
            return nil
        } catch is DecodingError {
            // Something else answers for /api/bloem/ here: not a Bloem server.
            return nil
        }
    }

    func register(_ server: AdminServer, _ request: PushRegisterRequest) async throws -> PushRegistered {
        try await signedInClient(server).registerPushDevice(request)
    }

    func setKinds(_ server: AdminServer, deviceID: String, kinds: [String: Bool]) async throws {
        _ = try await signedInClient(server).setPushKinds(deviceID: deviceID, kinds: kinds)
    }

    func setWidgets(_ server: AdminServer, deviceID: String, report: WidgetReport) async throws -> WidgetReport {
        try await signedInClient(server).setPushWidgets(deviceID: deviceID, report: report).report
    }

    private func signedInClient(_ server: AdminServer) -> APIClient {
        store.client(for: server, sessionState: sessionState)
    }
}
