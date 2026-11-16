import AuthenticationServices
import UIKit

/// How a browser sign-in ended, as far as the app can tell.
enum OAuthBrowserOutcome: Equatable, Sendable {
    /// The redirect, still unchecked.
    case callback(URL)
    /// The person closed the browser: no error is shown.
    case cancelled
    /// The system could not open a browser.
    case unavailable
    case failed
}

/// The system browser for a sign-in, behind a protocol so tests inject a fake that returns a callback
/// URL, a cancel or an error. The real one is `ASWebAuthenticationSession`: no WebView, and no URL
/// type is registered in `Info.plist`, so no other app can receive the redirect.
@MainActor
protocol OAuthBrowserSession: AnyObject, Sendable {
    func authenticate(startURL: URL, callbackScheme: String) async -> OAuthBrowserOutcome
    /// Closes a sign-in that is waiting. Its `authenticate` call returns `.cancelled`.
    func cancel()
}

@MainActor
final class SystemOAuthBrowserSession: NSObject, OAuthBrowserSession, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(startURL: URL, callbackScheme: String) async -> OAuthBrowserOutcome {
        // Only one sign-in at a time.
        cancel()
        let outcome: OAuthBrowserOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<OAuthBrowserOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let created = ASWebAuthenticationSession(url: startURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: .callback(callbackURL))
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(returning: .cancelled)
                    } else {
                        continuation.resume(returning: .failed)
                    }
                }
                created.presentationContextProvider = self
                created.prefersEphemeralWebBrowserSession = false
                session = created
                if !created.start() {
                    session = nil
                    continuation.resume(returning: .unavailable)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        return outcome
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
