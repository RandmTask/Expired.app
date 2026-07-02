import Foundation
import Supabase

/// Owns the Supabase session and authenticated calls to Edge Functions.
///
/// Identity is **anonymous by default**: `ensureSession()` silently signs the user in
/// at launch and that UUID becomes the RevenueCat `appUserID`. Subscription data stays
/// in CloudKit — Supabase holds only metering + entitlement state used to gate AI.
@MainActor
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: BackendConfig.supabaseURL,
            supabaseKey: BackendConfig.supabasePublishableKey
        )
    }

    /// Current user id (canonical lowercase UUID string) once a session exists, else nil.
    ///
    /// Swift's `UUID.uuidString` is always UPPERCASE, but the JWT `sub` claim that the
    /// `ai-proxy` Edge Function decodes — and the `auth.users.id` Postgres stores — are
    /// canonical LOWERCASE. RevenueCat treats `app_user_id` as case-sensitive, so handing
    /// it the uppercase form made the client attach purchases to an UPPERCASE RevenueCat
    /// customer while the server looked up a different, empty LOWERCASE one — every
    /// entitlement check came back `no_matching_entitlement`. Lowercasing here keeps the
    /// client's RevenueCat identity identical to what the server derives from the JWT.
    var currentUserID: String? {
        client.auth.currentUser?.id.uuidString.lowercased()
    }

    /// Ensures an authenticated session, creating an anonymous one if needed.
    /// Idempotent — reuses the persisted session on subsequent launches.
    @discardableResult
    func ensureSession() async throws -> User {
        if let session = try? await client.auth.session {
            return session.user
        }
        let session = try await client.auth.signInAnonymously()
        return session.user
    }

    /// Builds a request to an Edge Function pre-authorized with the current session's
    /// access token. The caller sets `httpBody`. Refreshes the session if needed.
    func authorizedFunctionRequest(_ name: String) async throws -> URLRequest {
        let token = try await client.auth.session.accessToken
        var request = URLRequest(url: BackendConfig.functionURL(name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(BackendConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        return request
    }

    /// Future "graduate anonymous account → permanent" flow (Sign in with Apple).
    /// Stubbed until cross-device sync / account protection is built.
    func linkWithApple(idToken: String, nonce: String) async throws {
        // try await client.auth.linkIdentity(...)  — intentionally not wired yet.
        assertionFailure("linkWithApple is not implemented yet")
    }
}
