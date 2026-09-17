import AppKit
import SwiftUI
import FiliconAccount

struct AccountWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var authorization = ""
    @State private var token = ""
    @State private var profile = ""
    @State private var entitlement = ""
    @State private var usage = ""
    @State private var feedback = l10n("")
    @State private var clientID = ""
    @State private var confirmingLogout = false

    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Section(l10n("Account")) {
                accountStatus
                HStack {
                    switch model.accountState {
                    case .loggedOut, .error, .expired:
                        Button(l10n("Sign In")) { Task { await model.beginAccountSignIn() } }
                            .disabled(!model.accountIsConfigured)
                    case .signingIn:
                        ProgressView().controlSize(.small)
                        Text(l10n("Continue sign-in in your browser.")).foregroundStyle(.secondary)
                        Button(l10n("Reopen")) { Task { await model.beginAccountSignIn() } }
                    case .signedIn:
                        Button(l10n("Refresh")) { Task { await model.refreshAccount() } }
                        Button(l10n("Sign Out…")) { confirmingLogout = true }
                    case .refreshing:
                        ProgressView().controlSize(.small)
                        Text(l10n("Refreshing account…")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n("Send Feedback…")) { model.showingFeedback = true }
                }
            }
            if let entitlement = model.accountEntitlement {
                Section(l10n("Access")) {
                    LabeledContent(l10n("Entitlement"), value: FiliconLocalization.string(entitlement.state.rawValue.capitalized))
                    if entitlement.reason != .none { LabeledContent(l10n("Reason"), value: FiliconLocalization.string(entitlement.reason.rawValue)) }
                }
            }
            if let usage = model.accountUsage {
                Section(l10n("Service usage")) {
                    if let fraction = usage.fractionUsed {
                        ProgressView(value: fraction)
                        LabeledContent(l10n("Included used"), value: "\(Int((fraction * 100).rounded()))%")
                    }
                    if let reset = usage.resetsAt { LabeledContent(l10n("Resets"), value: reset.formatted(.dateTime.locale(uiLocale))) }
                    if let used = usage.onDemandUsedMinorUnits {
                        let value = Double(used) / 100
                        if let limit = usage.onDemandLimitMinorUnits {
                            LabeledContent(l10n("On demand"), value: String(format: "$%.2f / $%.2f", value, Double(limit) / 100))
                        } else { LabeledContent(l10n("On demand"), value: String(format: "$%.2f", value)) }
                    }
                }
            }
            Section(l10n("Provider-neutral HTTPS service")) {
                Text(l10n("Optional. Filicon does not read another app’s private login. Configure a service implementing the documented OAuth/profile/entitlement/usage JSON contract."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(l10n("Authorization URL"), text: $authorization)
                TextField(l10n("Token URL"), text: $token)
                TextField(l10n("Profile URL"), text: $profile)
                TextField(l10n("Entitlement URL"), text: $entitlement)
                TextField(l10n("Usage URL"), text: $usage)
                TextField(l10n("Feedback URL (optional)"), text: $feedback)
                TextField(l10n("OAuth client ID"), text: $clientID)
                HStack {
                    Button(l10n("Save Service")) {
                        let values = (authorization, token, profile, entitlement, usage, feedback, clientID)
                        Task { await model.configureAccount(authorizationURL: values.0, tokenURL: values.1, profileURL: values.2, entitlementURL: values.3, usageURL: values.4, feedbackURL: values.5, clientID: values.6) }
                    }
                    Button(l10n("Use Local Mode")) {
                        authorization = ""; token = ""; profile = ""; entitlement = ""; usage = ""; feedback = l10n(""); clientID = ""
                        Task { await model.configureAccount(authorizationURL: "", tokenURL: "", profileURL: "", entitlementURL: "", usageURL: "", feedbackURL: "", clientID: "") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l10n("Account"))
        .onAppear(perform: load)
        .confirmationDialog(l10n("Sign out of Filicon?"), isPresented: $confirmingLogout) {
            Button(l10n("Sign Out"), role: .destructive) { Task { await model.logoutAccount() } }
            Button(l10n("Cancel"), role: .cancel) {}
        } message: {
            Text(l10n("Account-scoped preferences are detached. AI provider API keys remain in your Keychain."))
        }
    }

    @ViewBuilder private var accountStatus: some View {
        switch model.accountState {
        case .loggedOut(let retained):
            Label(retained ? l10n("Signed out; revoked credential tombstone retained") : l10n("Not signed in"), systemImage: "person.crop.circle.badge.xmark")
        case .signingIn:
            Label(l10n("Signing in"), systemImage: "person.crop.circle.badge.clock")
        case .signedIn(let session), .refreshing(let session):
            HStack(spacing: 10) {
                if let url = session.profile.avatarURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill") }
                        .frame(width: 38, height: 38).clipShape(Circle())
                } else { Image(systemName: "person.crop.circle.fill").font(.largeTitle) }
                VStack(alignment: .leading) {
                    Text(session.profile.displayName ?? session.profile.email ?? l10n("Signed in")).fontWeight(.semibold)
                    if let email = session.profile.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case .expired(let session):
            Label(l10n("Session expired\(session?.profile.email.map { ": \($0)" } ?? "")"), systemImage: "clock.badge.exclamationmark")
        case .error(let failure, _):
            Label(l10n("Account error: \(String(describing: failure))"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func load() {
        authorization = model.accountAuthorizationURL; token = model.accountTokenURL
        profile = model.accountProfileURL; entitlement = model.accountEntitlementURL
        usage = model.accountUsageURL; feedback = model.accountFeedbackURL; clientID = model.accountClientID
    }
}

struct AccountConnectionBanner: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let _ = uiLocale.identifier
        if ![ConnectionPhase.hidden, .connected].contains(model.accountConnection.phase) {
            HStack(spacing: 8) {
                if model.accountConnection.isRetrying || model.accountConnection.phase == .loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "network.slash").foregroundStyle(FiliconTheme.warning) }
                Text(message).font(.caption).foregroundStyle(FiliconTheme.textPrimary)
                Spacer()
                Button(l10n("Retry")) { Task { await model.retryAccountConnection() } }
                    .controlSize(.small)
                    .disabled(model.accountConnection.isRetrying)
                Button(l10n("Account")) { model.selectRoute(.account) }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(FiliconTheme.warning.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(FiliconTheme.warning.opacity(0.24)).frame(height: 0.7) }
        }
    }

    private var message: String {
        switch model.accountConnection.phase {
        case .loading: l10n("Connecting to the account service…")
        case .reconnecting: l10n("The account service disconnected. Filicon is retryable.")
        case .unreachable: l10n("The account service is unreachable. Local chats remain available.")
        default: ""
        }
    }
}

struct AccountAccessCover: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let _ = uiLocale.identifier
        if model.route != .account,
           let value = model.accountEntitlement,
           [.paymentRequired, .unavailable].contains(value.state) {
            ZStack {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: value.state == .paymentRequired ? "lock.circle" : "person.crop.circle.badge.exclamationmark").font(.system(size: 44))
                    Text(value.state == .paymentRequired ? l10n("Account access required") : l10n("Account setup is unavailable")).font(.title2.bold())
                    Text(l10n("The configured account service did not grant hosted access. Local conversations and settings remain on this Mac."))
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    HStack {
                        Button(l10n("Retry")) { Task { await model.retryAccountConnection() } }
                        Button(l10n("Open Account")) { model.selectRoute(.account) }
                        Button(l10n("Use Local Mode")) {
                            Task { await model.configureAccount(authorizationURL: "", tokenURL: "", profileURL: "", entitlementURL: "", usageURL: "", feedbackURL: "", clientID: "") }
                        }
                    }
                }.padding(32)
            }
        }
    }
}

struct FeedbackView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeConversation = false
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n("Send Feedback")).font(.title2.bold())
            Text(l10n("Tell us what happened. Credentials, tool secrets, and transcript contents are never attached automatically.")).foregroundStyle(.secondary)
            TextEditor(text: $message).frame(minHeight: 220).border(.quaternary)
                .onChange(of: message) { _, value in if value.count > 10_000 { message = String(value.prefix(10_000)) } }
            if model.selection != nil { Toggle(l10n("Include current conversation ID (not its transcript)"), isOn: $includeConversation) }
            if sent { Label(l10n("Feedback sent"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Text("\(message.count) / 10,000").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(sent ? l10n("Done") : l10n("Cancel")) { dismiss() }.disabled(sending)
                if !sent {
                    Button(sending ? l10n("Sending…") : l10n("Send")) {
                        sending = true
                        Task { sent = await model.submitFeedback(message: message, includeConversationID: includeConversation); sending = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(22).frame(minWidth: 560, minHeight: 430).interactiveDismissDisabled(sending)
    }
}

struct OnboardingView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var selected = Set<String>()

    private let suggestions = [
        OnboardingSuggestion(id: "chat", title: l10n("Ask and analyze"), priority: 100),
        OnboardingSuggestion(id: "files", title: l10n("Work with local files"), requiredCapability: "local-tools", priority: 90),
        OnboardingSuggestion(id: "automation", title: l10n("Run scheduled jobs"), requiredCapability: "automations", priority: 80),
        OnboardingSuggestion(id: "channels", title: l10n("Connect Slack or Discord"), requiredCapability: "channels", priority: 70),
        OnboardingSuggestion(id: "computer", title: l10n("Use the Mac or a remote computer"), requiredCapability: "computer", priority: 60),
    ]

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: progressFraction)
            Text(title).font(.largeTitle.bold())
            Text(detail).foregroundStyle(.secondary)
            switch model.onboardingProgress.current {
            case .landing, .meet:
                Label(model.descriptors.isEmpty ? l10n("AI providers are still loading") : l10n("\(model.descriptors.count) AI providers available"), systemImage: "sparkles")
            case .computerDemo:
                Label(l10n("Screen recording starts only when you explicitly choose Teach."), systemImage: "display")
            case .jobs, .tools:
                ForEach(filteredSuggestions, id: \.id) { suggestion in
                    Toggle(suggestion.title, isOn: Binding(get: { selected.contains(suggestion.id) }, set: { if $0 { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) } }))
                }
            case .create:
                Label(l10n("Create specialized agents later from the Agents workspace."), systemImage: "person.crop.circle.badge.plus")
            case .handOff:
                Label(l10n("You’re ready to use Filicon."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            HStack {
                Button(l10n("Skip setup")) { Task { await model.advanceOnboarding(to: .handOff) } }
                Spacer()
                Button(model.onboardingProgress.current == .create ? l10n("Finish") : l10n("Continue")) {
                    Task {
                        if [.jobs, .tools].contains(model.onboardingProgress.current) { await model.selectOnboardingSuggestions(Array(selected)) }
                        await model.advanceOnboarding(to: nextStep)
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(minWidth: 650, minHeight: 480).interactiveDismissDisabled()
    }

    private var filteredSuggestions: [OnboardingSuggestion] {
        selectOnboardingSuggestions(suggestions, capabilities: ["local-tools", "automations", "channels", "computer"])
    }
    private var progressFraction: Double {
        let all = OnboardingStep.allCases
        return Double(all.firstIndex(of: model.onboardingProgress.current) ?? 0) / Double(max(1, all.count - 1))
    }
    private var nextStep: OnboardingStep {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: model.onboardingProgress.current), index + 1 < all.count else { return .handOff }
        return all[index + 1]
    }
    private var title: String {
        switch model.onboardingProgress.current {
        case .landing: l10n("Welcome to Filicon")
        case .meet: l10n("Meet your AI workspace")
        case .computerDemo: l10n("Computer work is explicit")
        case .jobs: l10n("What do you want to automate?")
        case .tools: l10n("Choose useful capabilities")
        case .create: l10n("Create your first specialist")
        case .handOff: l10n("Ready")
        }
    }
    private var detail: String {
        switch model.onboardingProgress.current {
        case .landing: l10n("A native, macOS-only workspace for mainstream AI providers.")
        case .meet: l10n("Keys stay in macOS Keychain, and local mode does not require a Filicon account.")
        case .computerDemo: l10n("Local tools, remote computer access, and screen recording each have separate permission boundaries.")
        case .jobs: l10n("Select ideas to keep as setup suggestions. You can change everything later.")
        case .tools: l10n("Capabilities stay disabled until you configure and authorize them.")
        case .create: l10n("Agents, groups, channels, automations, MCP, plugins, and Shared Rooms are ready from the sidebar.")
        case .handOff: ""
        }
    }
}
