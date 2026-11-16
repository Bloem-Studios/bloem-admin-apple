import Foundation
import Observation

/// What the person confirms before a plan is applied: the plan change in a line, each setting that changes in plain
/// words, any warnings from the server, and who the change reaches.
struct PlanConfirmation: Equatable {
    let planName: String
    let headline: String
    let changes: [PlanChangeSummary.Change]
    let warnings: [String]
    let reach: String
}

/// An organization's plan on the platform: the plan it is on, the plans on offer, a preview of putting it on another
/// (what changes, setting by setting) and applying exactly that preview.
@Observable
@MainActor
final class PlatformPlanModel {
    let organizationID: String
    let organizationName: String
    private(set) var entitlement: OrganizationEntitlement?
    private(set) var plans: [EntitlementTemplate] = []
    private(set) var isLoading = true
    private(set) var failure: ServerSectionFailure?
    /// The plan chosen in the picker, by key. Empty when none is chosen.
    var selectedKey = ""
    private(set) var isPreviewing = false
    private(set) var isApplying = false
    /// Why the last preview or apply did not work.
    private(set) var actionError: String?
    private(set) var notice: String?

    /// What a preview came back with, kept with the plan it was made for and the key that names its apply.
    private struct Preview {
        let key: String
        let plan: EntitlementTemplate
        let result: EntitlementPreview
        let idempotencyKey: String
    }

    private var held: Preview?

    @ObservationIgnored private let pass: PlatformPass
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeIdempotencyKey: () -> String

    init(
        organizationID: String, organizationName: String, pass: PlatformPass,
        now: @escaping () -> Date = { Date() }, makeIdempotencyKey: @escaping () -> String = { UUID().uuidString }
    ) {
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.pass = pass
        self.now = now
        self.makeIdempotencyKey = makeIdempotencyKey
    }

    // MARK: What it is on now

    var hasNoPlans: Bool { !isLoading && failure == nil && plans.isEmpty }

    /// "Family, revision 3", "No plan yet", or the plan's key when it is no longer on offer.
    var currentPlanText: String {
        guard let entitlement else { return "" }
        guard entitlement.hasPlan else { return String(localized: "No plan yet") }
        return String(localized: "\(planName(forKey: entitlement.templateKey)), revision \(entitlement.templateRevision)")
    }

    /// True when the organization is on a plan the server no longer offers.
    var currentPlanUnavailable: Bool {
        guard let entitlement, entitlement.hasPlan else { return false }
        return !plans.contains { $0.key == entitlement.templateKey }
    }

    /// "8 screens · 2 conversions at once": what the whole organization may run.
    var limitsText: String {
        guard let entitlement else { return "" }
        return String(localized: "\(OrganizationText.screens(entitlement.slots)) · \(OrganizationText.conversions(entitlement.transcodes)) at once")
    }

    /// The default settings the plan gave members; empty before any plan was applied.
    var currentSettings: [PolicyWords.Row] {
        entitlement?.managedDefaultGroup.map { PolicyWords.rows($0.policy) } ?? []
    }

    var lastAppliedText: String? {
        guard let reconciled = entitlement?.lastReconciledAt else { return nil }
        return OrganizationText.when(reconciled)
    }

    var selectedPlan: EntitlementTemplate? { plans.first { $0.key == selectedKey } }

    private func planName(forKey key: String) -> String {
        plans.first { $0.key == key }?.name ?? key
    }

    // MARK: Loading

    func load(sessionState: ServerScopedSession?) async {
        isLoading = entitlement == nil
        failure = nil
        let hadSelection = !selectedKey.isEmpty
        do {
            let found = try await pass.read { try await $0.platformOrganizationEntitlement(id: organizationID) }
            let offered = try await pass.read { try await $0.platformEntitlementTemplates() }
            entitlement = found
            plans = offered
            isLoading = false
            if !hadSelection, found.hasPlan, offered.contains(where: { $0.key == found.templateKey }) {
                selectedKey = found.templateKey
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            failure = ErrorMessage.failure(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The plan couldn't be loaded. Check the connection and try again.")
            )
        }
    }

    // MARK: Previewing

    var canPreview: Bool { selectedPlan != nil && !isPreviewing && !isApplying }

    /// The preview for the plan now chosen; nil when none was made, it was made for another plan, or it changes nothing.
    private var currentPreview: Preview? {
        guard let held, held.key == selectedKey else { return nil }
        return held
    }

    var confirmation: PlanConfirmation? {
        guard let preview = currentPreview, preview.result.changed else { return nil }
        let result = preview.result.result
        let oldName = result.previousTemplateKey.isEmpty ? nil : planName(forKey: result.previousTemplateKey)
        return PlanConfirmation(
            planName: preview.plan.name,
            headline: PlanChangeSummary.headline(
                from: oldName, fromRevision: result.previousTemplateRevision, to: preview.plan.name, toRevision: result.templateRevision
            ),
            changes: PlanChangeSummary.changes(from: entitlement?.managedDefaultGroup?.policy, to: result.policy),
            warnings: preview.result.warnings,
            reach: String(localized: "Members on the default settings get these changes. Access groups \(organizationName) made itself stay as they are.")
        )
    }

    /// Said under the picker when the preview shows nothing to apply.
    var previewNote: String? {
        guard let preview = currentPreview, !preview.result.changed else { return nil }
        return String(localized: "Nothing changes: \(organizationName) already uses this plan")
    }

    /// True once the server's ten minutes for applying the preview are over.
    var previewExpired: Bool {
        guard let preview = currentPreview, let expiresAt = preview.result.expiresAt.flatMap(OrganizationText.parse) else { return false }
        return now() >= expiresAt
    }

    var canApply: Bool {
        guard let preview = currentPreview else { return false }
        return preview.result.changed && !previewExpired && !isApplying && !isPreviewing
    }

    /// Asks the server what putting the organization on the chosen plan would change. Nothing is changed.
    func preview(sessionState: ServerScopedSession?) async {
        guard let plan = selectedPlan, canPreview else { return }
        isPreviewing = true
        actionError = nil
        notice = nil
        held = nil
        defer { isPreviewing = false }
        do {
            // A preview changes nothing, so a stale pass is renewed and the question asked again.
            let result = try await pass.read {
                try await $0.dryRunPlatformOrganizationEntitlement(id: organizationID, templateKey: plan.key, templateRevision: plan.revision)
            }
            held = Preview(key: plan.key, plan: plan, result: result, idempotencyKey: makeIdempotencyKey())
        } catch is CancellationError {
            return
        } catch {
            actionError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The preview couldn't be made. Check the connection and try again.")
            )
        }
    }

    // MARK: Applying

    /// Puts the organization on the plan that was previewed, with the preview's token. Sent once.
    func apply(sessionState: ServerScopedSession?) async {
        guard canApply, let preview = currentPreview else { return }
        isApplying = true
        actionError = nil
        notice = nil
        defer { isApplying = false }
        do {
            _ = try await pass.write {
                try await $0.applyPlatformOrganizationEntitlement(
                    id: organizationID, templateKey: preview.plan.key, templateRevision: preview.plan.revision,
                    token: preview.result.token, idempotencyKey: preview.idempotencyKey
                )
            }
            held = nil
            notice = String(localized: "\(organizationName) is now on \(preview.plan.name)")
            await load(sessionState: sessionState)
            if failure != nil {
                // Saved, but the page could not be refreshed: say so instead of hiding the success.
                failure = nil
                actionError = String(localized: "The plan was applied, but this page couldn't be refreshed. Pull down to refresh.")
            }
        } catch is PlatformStateChanged {
            held = nil
            actionError = String(localized: "Your administrator access was renewed. Preview the change again to apply it.")
        } catch let error as APIError where error.code == "confirmation_stale" {
            held = nil
            actionError = String(localized: "The plan changed since the preview. Preview again to see what it does now.")
        } catch is CancellationError {
            return
        } catch {
            // The preview stays: applying it again names the same attempt, so the server never applies it twice.
            actionError = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The plan couldn't be applied. Check the connection and try again.")
            )
        }
    }
}
