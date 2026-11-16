import Foundation

/// Helping one person back in, on a server with organization support: a reset link by email or to hand over, signing
/// out everywhere, of one session or of one device, and adding, renaming, clearing the PIN of or removing a profile.
///
/// Every action is one write through the pass, sent once. The server judges who may act on whom: a protected person
/// comes back as `409 target_protected` with a reason, which the page shows in words. A stale revision reloads the
/// person and says so; nothing is ever replayed.
extension OrganizationPersonViewModel {
    // MARK: Reset links

    /// Issues a reset link. An emailed link goes to the person's own address; a link to hand over is shown once.
    func issueReset(session: OrganizationSession, delivery: PasswordResetDelivery) async {
        guard let person else { return }
        await supportWrite(
            session: session, fallback: String(localized: "The reset link couldn't be confirmed. Issuing another one replaces it.")
        ) { client, _ in
            try await client.issueOrganizationPasswordReset(accountID: person.accountID, delivery: delivery, revision: person.securityRevision)
        } apply: { response in
            self.show(response.person)
            switch delivery {
            case .link:
                guard let url = response.reset.resetURL else {
                    self.errorMessage = String(localized: "The server didn't return a link. Create another one.")
                    return nil
                }
                self.resetLink = ResetLinkHandoff(url: url, expiresAt: response.reset.expiresAt, personLabel: response.person.label)
                return nil
            case .email:
                if response.reset.deliveryStatus == SupportReset.deliveryUncertain {
                    return String(localized: "The email may not have been sent. The link works anyway; send another, or create a link to hand over.")
                }
                return String(localized: "A reset email is on its way to \(response.person.email). The link works for 24 hours.")
            }
        }
    }

    /// Forgets the link. The page never keeps it once the administrator has closed it.
    func dismissResetLink() {
        resetLink = nil
    }

    // MARK: Sessions and devices

    /// Ends every session of the person; they sign in again everywhere. Their personal API keys keep working.
    func signOutEverywhere(session: OrganizationSession) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The sign-out couldn't be confirmed. Check their sign-ins before trying again.")) { client, _ in
            try await client.signOutOrganizationPersonEverywhere(accountID: person.accountID, revision: person.securityRevision)
        } apply: { response in
            self.show(response.person)
            await self.reloadSignIns(session: session, accountID: person.accountID)
            let count = Int(response.revoked.sessions)
            return count == 1
                ? String(localized: "Signed out everywhere: 1 session ended")
                : String(localized: "Signed out everywhere: \(count) sessions ended")
        }
    }

    func signOut(session: OrganizationSession, of signIn: SupportSession) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The sign-out couldn't be confirmed. Check their sign-ins before trying again.")) { client, _ in
            try await client.signOutOrganizationPersonSession(accountID: person.accountID, sessionID: signIn.id)
        } apply: { _ in
            await self.reloadSignIns(session: session, accountID: person.accountID)
            return String(localized: "Signed out of that session")
        }
    }

    func signOut(session: OrganizationSession, of device: SupportDevice) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The sign-out couldn't be confirmed. Check their devices before trying again.")) { client, _ in
            try await client.signOutOrganizationPersonDevice(accountID: person.accountID, deviceID: device.deviceID)
        } apply: { _ in
            await self.reloadSignIns(session: session, accountID: person.accountID)
            return String(localized: "Signed out of \(OrganizationText.deviceName(device.name))")
        }
    }

    // MARK: Profiles

    func addProfile(session: OrganizationSession, name: String, groupID: Int64?) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The profile couldn't be confirmed. Check their profiles before trying again.")) { client, _ in
            try await client.createOrganizationProfile(accountID: person.accountID, name: name, groupID: groupID)
        } apply: { response in
            self.show(response.person)
            return String(localized: "Profile \(response.profile.name) added")
        }
    }

    func renameProfile(session: OrganizationSession, profile: ProfileSummary, to name: String) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The new name couldn't be confirmed. Check the profile before trying again.")) { client, _ in
            try await client.renameOrganizationProfile(accountID: person.accountID, profileID: profile.id, name: name, revision: profile.revision)
        } apply: { response in
            self.show(response.person)
            return String(localized: "Profile renamed to \(response.profile.name)")
        }
    }

    func clearPIN(session: OrganizationSession, profile: ProfileSummary) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The PIN change couldn't be confirmed. Check the profile before trying again.")) { client, _ in
            try await client.clearOrganizationProfilePIN(accountID: person.accountID, profileID: profile.id, revision: profile.revision)
        } apply: { cleared in
            if let current = self.person { self.show(current.replacing(cleared)) }
            return String(localized: "PIN cleared on \(cleared.name). They choose a new one on the profile.")
        }
    }

    func removeProfile(session: OrganizationSession, profile: ProfileSummary) async {
        guard let person else { return }
        await supportWrite(session: session, fallback: String(localized: "The removal couldn't be confirmed. Check their profiles before trying again.")) { client, _ in
            try await client.removeOrganizationProfile(accountID: person.accountID, profileID: profile.id, revision: profile.revision)
        } apply: { _ in
            // The answer is empty: read the person again for the profiles that are left.
            if case .ok(let updated) = await session.attemptRead(fallback: "", { try await $0.organizationPerson(accountID: person.accountID) }) {
                self.show(updated)
            }
            return String(localized: "Profile \(profile.name) removed")
        }
    }

    // MARK: One write

    /// Sends `write` once. On success `apply` updates the page and returns the notice to show (nil for none). On
    /// failure the person is read again, so the page shows what the server holds now, and the reason is shown.
    private func supportWrite<T>(
        session: OrganizationSession,
        fallback: String,
        _ write: (APIClient, Int64) async throws -> T,
        apply: @MainActor (T) async -> String?
    ) async {
        guard let person, !isPending else { return }
        isPending = true
        errorMessage = nil
        notice = nil
        let outcome = await session.attemptWrite(fallback: fallback, write)
        switch outcome {
        case .ok(let value):
            notice = await apply(value)
            isPending = false
            await refreshChanges(session: session, person: self.person ?? person)
        case .failed(let message):
            isPending = false
            await load(session: session, accountID: person.accountID)
            errorMessage = message
        case .cancelled:
            isPending = false
        }
    }
}
