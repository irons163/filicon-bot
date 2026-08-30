import SwiftUI
import FiliconPlugins

struct SkillPublishingSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = ""
    @State private var bearer = ""
    @State private var selectedTarget = ""

    var body: some View {
        Section("Team Marketplace Publishing") {
            Text("Publish through a provider-neutral HTTPS service. Credentials are stored in Keychain; team changes fail closed when no backend is configured.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("https://marketplace.example/api/", text: $endpoint)
                SecureField("Bearer token", text: $bearer).frame(maxWidth: 220)
                Button("Save & Connect") {
                    let endpoint = endpoint, bearer = bearer
                    Task { if await model.configureSkillPublishing(endpoint: endpoint, bearerToken: bearer) { self.bearer = "" } }
                }
                Button("Disable", role: .destructive) {
                    endpoint = ""; bearer = ""
                    Task { _ = await model.configureSkillPublishing(endpoint: "", bearerToken: "") }
                }.disabled(model.skillPublishingEndpoint.isEmpty)
            }
            if model.skillPublishingEndpoint.isEmpty {
                Label("No backend configured", systemImage: "lock.shield").foregroundStyle(.secondary)
            } else {
                HStack {
                    Label(model.skillPublishingEndpoint, systemImage: "network").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Refresh") { Task { await model.refreshSkillPublishing() } }
                        .disabled(model.isRefreshingSkillPublishing)
                }
                if model.skillPublishTargets.isEmpty {
                    Text("No authorized publishing targets were returned.").foregroundStyle(.secondary)
                } else {
                    Picker("Target", selection: $selectedTarget) {
                        Text("Choose…").tag("")
                        ForEach(model.skillPublishTargets) { target in
                            Text("\(target.name) · \(authorizationLabel(target.authorizationState))").tag(target.id)
                        }
                    }
                }
            }
            ForEach(model.privateSkills) { skill in
                PrivatePublicationRow(skill: skill, state: model.skillPublicationStates.first { $0.skillID == skill.id }, selectedTarget: selectedTarget)
            }
            ForEach(model.indexedPluginSkills.filter { $0.marketplaceTeamID != nil }) { skill in
                IndexedPublicationRow(skill: skill)
            }
        }
        .onAppear {
            endpoint = model.skillPublishingEndpoint
            if selectedTarget.isEmpty { selectedTarget = firstAuthorizedTarget(in: model.skillPublishTargets) }
        }
        .onChange(of: model.skillPublishTargets) { _, targets in
            if !targets.contains(where: { $0.id == selectedTarget }) { selectedTarget = firstAuthorizedTarget(in: targets) }
        }
    }

    private func authorizationLabel(_ state: PluginAuthorizationState) -> String {
        switch state { case .authorized: "authorized"; case .notRequired: "no auth required"; case .required: "authentication required"; case .pending: "authorization pending"; case .failed: "authorization failed" }
    }

    private func firstAuthorizedTarget(in targets: [SkillPublishTarget]) -> String {
        for target in targets where target.authorizationState == .authorized || target.authorizationState == .notRequired { return target.id }
        return ""
    }
}

private struct PrivatePublicationRow: View {
    @EnvironmentObject private var model: AppModel
    let skill: PrivateSkillRecord
    let state: SkillPublicationState?
    let selectedTarget: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                if let state {
                    Text(statusLabel(state)).font(.caption).foregroundColor(state.phase == .failed ? .red : .secondary)
                    if let error = state.errorMessage { Text(error).font(.caption2).foregroundStyle(.red) }
                } else {
                    Text("Local · owned by you").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state?.pluginID != nil {
                Button("Resync") { Task { await model.resyncPrivateSkill(id: skill.id) } }
                Button("Unpublish", role: .destructive) { Task { await model.unpublishPrivateSkill(id: skill.id) } }
            } else {
                Button("Publish") { Task { await model.publishPrivateSkill(id: skill.id, targetID: selectedTarget) } }
                    .disabled(selectedTarget.isEmpty || model.skillPublishingEndpoint.isEmpty)
            }
        }
    }

    private func statusLabel(_ state: SkillPublicationState) -> String {
        let owner = state.pluginID == nil ? "ownership pending" : "owned by current credential"
        return "\(state.phase.rawValue.capitalized) · \(owner) · target \(state.targetID)" + (state.version.map { " · \($0)" } ?? "")
    }
}

private struct IndexedPublicationRow: View {
    @EnvironmentObject private var model: AppModel
    let skill: IndexedPluginSkill

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                Text(ownershipText).font(.caption).foregroundColor(skill.publishedByCurrentUser ? .secondary : .orange)
            }
            Spacer()
            Button("Resync") { Task { await model.resyncPublishedPluginSkill(id: skill.id) } }
            Button("Unpublish", role: .destructive) { Task { await model.unpublishPublishedPluginSkill(id: skill.id) } }
        }
        .disabled(!skill.publishedByCurrentUser || model.skillPublishingEndpoint.isEmpty)
    }

    private var ownershipText: String {
        if skill.publishedByCurrentUser { return "Team-managed · owned by current user · target \(skill.marketplaceTeamID ?? "")" }
        return "Team-managed · owned by another publisher"
    }
}
