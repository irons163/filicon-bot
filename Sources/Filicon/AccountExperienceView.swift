import AppKit
import SwiftUI
import FiliconAccount

struct AccountWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var authorization = ""
    @State private var token = ""
    @State private var profile = ""
    @State private var entitlement = ""
    @State private var usage = ""
    @State private var feedback = ""
    @State private var clientID = ""
    @State private var confirmingLogout = false

    var body: some View {
        Form {
            Section("Account") {
                accountStatus
                HStack {
                    switch model.accountState {
                    case .loggedOut, .error, .expired:
                        Button("Sign In") { Task { await model.beginAccountSignIn() } }
                            .disabled(!model.accountIsConfigured)
                    case .signingIn:
                        ProgressView().controlSize(.small)
                        Text("Continue sign-in in your browser.").foregroundStyle(.secondary)
                        Button("Reopen") { Task { await model.beginAccountSignIn() } }
                    case .signedIn:
                        Button("Refresh") { Task { await model.refreshAccount() } }
                        Button("Sign Out…") { confirmingLogout = true }
                    case .refreshing:
                        ProgressView().controlSize(.small)
                        Text("Refreshing account…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Send Feedback…") { model.showingFeedback = true }
                }
            }
            if let entitlement = model.accountEntitlement {
                Section("Access") {
                    LabeledContent("Entitlement", value: entitlement.state.rawValue.capitalized)
                    if entitlement.reason != .none { LabeledContent("Reason", value: entitlement.reason.rawValue) }
                }
            }
            if let usage = model.accountUsage {
                Section("Service usage") {
                    if let fraction = usage.fractionUsed {
                        ProgressView(value: fraction)
                        LabeledContent("Included used", value: "\(Int((fraction * 100).rounded()))%")
                    }
                    if let reset = usage.resetsAt { LabeledContent("Resets", value: reset.formatted()) }
                    if let used = usage.onDemandUsedMinorUnits {
                        let value = Double(used) / 100
                        if let limit = usage.onDemandLimitMinorUnits {
                            LabeledContent("On demand", value: String(format: "$%.2f / $%.2f", value, Double(limit) / 100))
                        } else { LabeledContent("On demand", value: String(format: "$%.2f", value)) }
                    }
                }
            }
            Section("Provider-neutral HTTPS service") {
                Text("Optional. Filicon does not read another app’s private login. Configure a service implementing the documented OAuth/profile/entitlement/usage JSON contract.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Authorization URL", text: $authorization)
                TextField("Token URL", text: $token)
                TextField("Profile URL", text: $profile)
                TextField("Entitlement URL", text: $entitlement)
                TextField("Usage URL", text: $usage)
                TextField("Feedback URL (optional)", text: $feedback)
                TextField("OAuth client ID", text: $clientID)
                HStack {
                    Button("Save Service") {
                        let values = (authorization, token, profile, entitlement, usage, feedback, clientID)
                        Task { await model.configureAccount(authorizationURL: values.0, tokenURL: values.1, profileURL: values.2, entitlementURL: values.3, usageURL: values.4, feedbackURL: values.5, clientID: values.6) }
                    }
                    Button("Use Local Mode") {
                        authorization = ""; token = ""; profile = ""; entitlement = ""; usage = ""; feedback = ""; clientID = ""
                        Task { await model.configureAccount(authorizationURL: "", tokenURL: "", profileURL: "", entitlementURL: "", usageURL: "", feedbackURL: "", clientID: "") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .onAppear(perform: load)
        .confirmationDialog("Sign out of Filicon?", isPresented: $confirmingLogout) {
            Button("Sign Out", role: .destructive) { Task { await model.logoutAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Account-scoped preferences are detached. AI provider API keys remain in your Keychain.")
        }
    }

    @ViewBuilder private var accountStatus: some View {
        switch model.accountState {
        case .loggedOut(let retained):
            Label(retained ? "Signed out; revoked credential tombstone retained" : "Not signed in", systemImage: "person.crop.circle.badge.xmark")
        case .signingIn:
            Label("Signing in", systemImage: "person.crop.circle.badge.clock")
        case .signedIn(let session), .refreshing(let session):
            HStack(spacing: 10) {
                if let url = session.profile.avatarURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill") }
                        .frame(width: 38, height: 38).clipShape(Circle())
                } else { Image(systemName: "person.crop.circle.fill").font(.largeTitle) }
                VStack(alignment: .leading) {
                    Text(session.profile.displayName ?? session.profile.email ?? "Signed in").fontWeight(.semibold)
                    if let email = session.profile.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case .expired(let session):
            Label("Session expired\(session?.profile.email.map { ": \($0)" } ?? "")", systemImage: "clock.badge.exclamationmark")
        case .error(let failure, _):
            Label("Account error: \(String(describing: failure))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func load() {
        authorization = model.accountAuthorizationURL; token = model.accountTokenURL
        profile = model.accountProfileURL; entitlement = model.accountEntitlementURL
        usage = model.accountUsageURL; feedback = model.accountFeedbackURL; clientID = model.accountClientID
    }
}

struct AccountConnectionBanner: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if ![ConnectionPhase.hidden, .connected].contains(model.accountConnection.phase) {
            HStack(spacing: 8) {
                if model.accountConnection.isRetrying || model.accountConnection.phase == .loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "network.slash").foregroundStyle(.orange) }
                Text(message).font(.callout)
                Spacer()
                Button("Retry") { Task { await model.retryAccountConnection() } }
                    .disabled(model.accountConnection.isRetrying)
                Button("Account") { model.selectRoute(.account) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.orange.opacity(0.12))
        }
    }

    private var message: String {
        switch model.accountConnection.phase {
        case .loading: "Connecting to the account service…"
        case .reconnecting: "The account service disconnected. Filicon is retryable."
        case .unreachable: "The account service is unreachable. Local chats remain available."
        default: ""
        }
    }
}

struct AccountAccessCover: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.route != .account,
           let value = model.accountEntitlement,
           [.paymentRequired, .unavailable].contains(value.state) {
            ZStack {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: value.state == .paymentRequired ? "lock.circle" : "person.crop.circle.badge.exclamationmark").font(.system(size: 44))
                    Text(value.state == .paymentRequired ? "Account access required" : "Account setup is unavailable").font(.title2.bold())
                    Text("The configured account service did not grant hosted access. Local conversations and settings remain on this Mac.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    HStack {
                        Button("Retry") { Task { await model.retryAccountConnection() } }
                        Button("Open Account") { model.selectRoute(.account) }
                        Button("Use Local Mode") {
                            Task { await model.configureAccount(authorizationURL: "", tokenURL: "", profileURL: "", entitlementURL: "", usageURL: "", feedbackURL: "", clientID: "") }
                        }
                    }
                }.padding(32)
            }
        }
    }
}

struct FeedbackView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeConversation = false
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send Feedback").font(.title2.bold())
            Text("Tell us what happened. Credentials, tool secrets, and transcript contents are never attached automatically.").foregroundStyle(.secondary)
            TextEditor(text: $message).frame(minHeight: 220).border(.quaternary)
                .onChange(of: message) { _, value in if value.count > 10_000 { message = String(value.prefix(10_000)) } }
            if model.selection != nil { Toggle("Include current conversation ID (not its transcript)", isOn: $includeConversation) }
            if sent { Label("Feedback sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Text("\(message.count) / 10,000").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(sent ? "Done" : "Cancel") { dismiss() }.disabled(sending)
                if !sent {
                    Button(sending ? "Sending…" : "Send") {
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
    @EnvironmentObject private var model: AppModel
    @State private var selected = Set<String>()

    private let suggestions = [
        OnboardingSuggestion(id: "chat", title: "Ask and analyze", priority: 100),
        OnboardingSuggestion(id: "files", title: "Work with local files", requiredCapability: "local-tools", priority: 90),
        OnboardingSuggestion(id: "automation", title: "Run scheduled jobs", requiredCapability: "automations", priority: 80),
        OnboardingSuggestion(id: "channels", title: "Connect Slack or Discord", requiredCapability: "channels", priority: 70),
        OnboardingSuggestion(id: "computer", title: "Use the Mac or a remote computer", requiredCapability: "computer", priority: 60),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: progressFraction)
            Text(title).font(.largeTitle.bold())
            Text(detail).foregroundStyle(.secondary)
            switch model.onboardingProgress.current {
            case .landing, .meet:
                Label(model.descriptors.isEmpty ? "AI providers are still loading" : "\(model.descriptors.count) AI providers available", systemImage: "sparkles")
            case .computerDemo:
                Label("Screen recording starts only when you explicitly choose Teach.", systemImage: "display")
            case .jobs, .tools:
                ForEach(filteredSuggestions, id: \.id) { suggestion in
                    Toggle(suggestion.title, isOn: Binding(get: { selected.contains(suggestion.id) }, set: { if $0 { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) } }))
                }
            case .create:
                Label("Create specialized agents later from the Agents workspace.", systemImage: "person.crop.circle.badge.plus")
            case .handOff:
                Label("You’re ready to use Filicon.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            HStack {
                Button("Skip setup") { Task { await model.advanceOnboarding(to: .handOff) } }
                Spacer()
                Button(model.onboardingProgress.current == .create ? "Finish" : "Continue") {
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
        case .landing: "Welcome to Filicon"
        case .meet: "Meet your AI workspace"
        case .computerDemo: "Computer work is explicit"
        case .jobs: "What do you want to automate?"
        case .tools: "Choose useful capabilities"
        case .create: "Create your first specialist"
        case .handOff: "Ready"
        }
    }
    private var detail: String {
        switch model.onboardingProgress.current {
        case .landing: "A native, macOS-only workspace for mainstream AI providers."
        case .meet: "Keys stay in macOS Keychain, and local mode does not require a Filicon account."
        case .computerDemo: "Local tools, remote computer access, and screen recording each have separate permission boundaries."
        case .jobs: "Select ideas to keep as setup suggestions. You can change everything later."
        case .tools: "Capabilities stay disabled until you configure and authorize them."
        case .create: "Agents, groups, channels, automations, MCP, plugins, and Shared Rooms are ready from the sidebar."
        case .handOff: ""
        }
    }
}
