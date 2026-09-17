import Foundation
import Testing
import FiliconAgents
@testable import Filicon

@Suite("Inline group member editing")
@MainActor
struct GroupMemberEditingTests {
    @Test func creationSelectsPersistedIdentityAndPreservesOtherDraftFields() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let original = try #require(await model.createAgent(name: "Same name", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream"))
        #expect(await model.createGroup(name: "Team", summary: "Original", memberIDs: [original.id]))
        let group = try #require(model.groups.first)
        var draft = GroupSettingsDraft(group: group)
        draft.name = "Unsaved name"
        draft.summary = "Unsaved description"
        let destination = GroupMemberEditorDestination(profile: AgentProfile(name: ""), isNew: true)

        // A prior unrelated error must not make the editor treat this successful save as a failure.
        model.errorMessage = "Earlier unrelated error"
        let created = try #require(await model.createAgent(name: "Same name", summary: "", instructions: "Plan", providerID: "fake", modelID: "fake-stream", avatar: .pet(.dewey)))
        destination.memberSaved(created, selection: &draft.memberIDs)
        #expect(draft.memberIDs.contains(original.id))
        #expect(draft.memberIDs.contains(created.id))
        #expect(!draft.memberIDs.contains(destination.profile.id))
        #expect(draft.name == "Unsaved name")
        #expect(draft.summary == "Unsaved description")
        #expect(!model.groups[0].memberIDs.contains(created.id))

        #expect(await model.saveGroupSettings(groupID: group.id, name: draft.name, summary: draft.summary, memberIDs: draft.orderedMembers(agents: model.agents, preserving: group.memberIDs)))
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        #expect(reopened.groups.first?.memberIDs == [original.id, created.id])
        #expect(reopened.groups.first?.name == draft.name)
        #expect(reopened.agents.contains { $0.id == created.id && $0.avatar == .pet(.dewey) })
    }

    @Test func editingChangesSharedProfileWithoutSelectingItOrChangingGroups() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        var profile = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "Before", providerID: "fake", modelID: "fake-stream"))
        #expect(await model.createGroup(name: "First", summary: "", memberIDs: [profile.id]))
        #expect(await model.createGroup(name: "Second", summary: "", memberIDs: [profile.id]))
        let groupsBefore = model.groups
        let destination = GroupMemberEditorDestination(profile: profile, isNew: false)
        var selection: Set<UUID> = []
        profile.name = "Builder"
        profile.instructions = "After"
        profile.avatar = .pet(.hoots)
        model.errorMessage = "Earlier unrelated error"
        #expect(await model.updateAgent(profile))
        let saved = try #require(model.agents.first { $0.id == profile.id })
        destination.memberSaved(saved, selection: &selection)
        #expect(selection.isEmpty)
        #expect(model.groups == groupsBefore)

        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        let restored = try #require(reopened.agents.first { $0.id == profile.id })
        #expect(restored.name == "Builder")
        #expect(restored.instructions == "After")
        #expect(restored.avatar == .pet(.hoots))
        #expect(reopened.groups.allSatisfy { $0.memberIDs.contains(profile.id) })
    }

    @Test func failedSaveDoesNotReturnSuccessOrChangePublishedProfiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        #expect(await model.createAgent(name: " \n ", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream") == nil)
        #expect(model.agents.isEmpty)
        var profile = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream"))
        let before = model.agents
        profile.name = " "
        #expect(!(await model.updateAgent(profile)))
        #expect(model.agents == before)
        #expect(model.errorMessage != nil)
    }

    @Test func onlySuccessfulCreationSelectsAMemberAndRespectsLimit() {
        let profiles = (1...7).map { index in
            AgentProfile(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, name: "Member \(index)", createdAt: Date(timeIntervalSince1970: 0))
        }
        var selection = Set(profiles.prefix(GroupService.maximumMembers).map(\.id))
        let destination = GroupMemberEditorDestination(profile: profiles.last!, isNew: true)
        destination.memberSaved(profiles.last!, selection: &selection)
        #expect(!selection.contains(profiles.last!.id))
        selection.remove(profiles[0].id)
        destination.memberSaved(profiles.last!, selection: &selection)
        #expect(selection.count == GroupService.maximumMembers)
        #expect(selection.contains(profiles.last!.id))
        #expect(!selection.contains(profiles[0].id))
        destination.memberSaved(profiles.last!, selection: &selection)
        #expect(selection.count == GroupService.maximumMembers)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func newControlsHaveTranslations(language: String) {
        for key in ["New member", "Edit {0}", "Changes to this agent apply to every group.", "Groups can have up to {0} members.", "New members are selected automatically. Save to apply membership changes."] {
            let translated = FiliconLocalization.string(key, language: language)
            #expect(!translated.isEmpty)
            if language != "en" { #expect(translated != key) }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "filicon-member-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
