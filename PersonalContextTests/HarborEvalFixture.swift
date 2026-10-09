import SwiftData
@testable import Slate

@MainActor
enum HarborEvalFixture {
    static let authBody = "Use the existing local session store. Do not add a cloud account."
    static let authBodyWithOffline = authBody + " Sign-in must work offline."
    static let tokensBody = "Refresh fails after waking from sleep."
    static let vendorLead = "Vendor sample uses a hosted account service."
    static let vendorTail = "FULL_NOTE_TAIL"
    static let billingSentinel = "BILLING_SENTINEL_INVOICE_SCHEMA"

    static var vendorContent: String {
        vendorLead + " " + String(repeating: "VENDOR_DOC ", count: 80) + vendorTail
    }

    struct Seed {
        var project: Project
        var auth: ProjectThread
        var tokens: ProjectThread
        var billing: ProjectThread
        var oauthNote: Note
        var billingNote: Note
        var decision: Decision
        var shipSignIn: AgendaItem
        var fixRefresh: AgendaItem
        var billingTask: AgendaItem
    }

    static func seed(in context: ModelContext) -> Seed {
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let auth = ProjectThread(title: "Auth", kind: .feature, project: project)
        auth.summary = "Users can sign in"
        auth.body = authBody
        let tokens = ProjectThread(title: "Tokens", kind: .problem, project: project, parent: auth)
        tokens.summary = "Refresh is flaky"
        tokens.body = tokensBody
        let billing = ProjectThread(title: "Billing", kind: .feature, project: project)
        billing.summary = "Invoices and plans"
        billing.body = "Retry failed invoice webhooks."
        let oauthNote = Note(
            content: vendorContent,
            project: project,
            title: "OAuth vendor reference",
            thread: auth
        )
        let billingNote = Note(
            content: billingSentinel,
            project: project,
            title: "Invoice schema",
            thread: billing
        )
        let decision = Decision(
            title: "Keep the Mac session",
            decision: "Keep the local session. Do not add a cloud account.",
            project: project,
            thread: auth
        )
        let shipSignIn = AgendaItem(kind: .task, eventKitID: "", title: "Ship sign-in")
        let fixRefresh = AgendaItem(kind: .task, eventKitID: "", title: "Fix refresh after wake")
        let billingTask = AgendaItem(kind: .task, eventKitID: "", title: "Retry invoice webhooks")
        context.insert(project)
        context.insert(auth)
        context.insert(tokens)
        context.insert(billing)
        context.insert(oauthNote)
        context.insert(billingNote)
        context.insert(decision)
        context.insert(shipSignIn)
        context.insert(fixRefresh)
        context.insert(billingTask)
        AssociationService.assignUserProject(project, on: shipSignIn)
        AssociationService.assignUserProject(project, on: fixRefresh)
        AssociationService.assignUserProject(project, on: billingTask)
        AssociationService.applyLink(thread: auth, onto: shipSignIn)
        AssociationService.applyLink(thread: tokens, onto: fixRefresh)
        AssociationService.applyLink(thread: billing, onto: billingTask)
        TaskStore.setStatus(.blocked, on: fixRefresh, in: context)
        return Seed(
            project: project,
            auth: auth,
            tokens: tokens,
            billing: billing,
            oauthNote: oauthNote,
            billingNote: billingNote,
            decision: decision,
            shipSignIn: shipSignIn,
            fixRefresh: fixRefresh,
            billingTask: billingTask
        )
    }
}
