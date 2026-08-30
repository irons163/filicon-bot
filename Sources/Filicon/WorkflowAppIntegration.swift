import Foundation
import FiliconDomain
import FiliconProviderKit
import FiliconAgents
import FiliconAutomations

extension AppModel {
    func reloadWorkflows() async {
        guard let workflowService else {
            workflowError = "Workflow storage is unavailable."
            return
        }
        workflowIsLoading = true
        defer { workflowIsLoading = false }
        workflows = await workflowService.workflows()
        workflowRuns = await workflowService.runs()
        workflowError = nil
        reconcileWorkflowSchedules(now: .now)
    }

    func saveWorkflow(_ proposed: AgentWorkflow, replacingID: String? = nil) async -> Bool {
        guard let workflowService else { workflowError = "Workflow storage is unavailable."; return false }
        do {
            if let replacingID { _ = try await workflowService.update(id: replacingID, with: proposed) }
            else { _ = try await workflowService.create(proposed) }
            await reloadWorkflows()
            return true
        } catch {
            workflowError = error.localizedDescription
            return false
        }
    }

    func setWorkflowEnabled(id: String, enabled: Bool) async {
        guard let workflowService else { return }
        do { _ = try await workflowService.setEnabled(enabled, id: id); await reloadWorkflows() }
        catch { workflowError = error.localizedDescription }
    }

    func deleteWorkflow(id: String) async {
        guard let workflowService else { return }
        do { try await workflowService.delete(id: id); workflowNextRuns[id] = nil; await reloadWorkflows() }
        catch { workflowError = error.localizedDescription }
    }

    func runWorkflowNow(id: String) async {
        guard let workflowService else { return }
        do { _ = try await workflowService.runNow(id: id); await reloadWorkflows() }
        catch { workflowError = error.localizedDescription }
    }

    func cancelWorkflow(id: String) async {
        await workflowService?.cancel(workflowID: id)
        await reloadWorkflows()
    }

    func cancelWorkflowRun(id: UUID) async {
        await workflowService?.cancel(runID: id)
        await reloadWorkflows()
    }

    func replayWorkflowRun(id: UUID) async {
        guard let workflowService else { return }
        do { _ = try await workflowService.replay(runID: id); await reloadWorkflows() }
        catch { workflowError = error.localizedDescription }
    }

    func importWorkflowText(_ markdown: String, fallbackName: String? = nil) async -> Bool {
        guard let workflowService else { return false }
        do { _ = try await workflowService.importText(markdown, fallbackName: fallbackName); await reloadWorkflows(); return true }
        catch { workflowError = error.localizedDescription; return false }
    }

    func importWorkflowFile(_ url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AgentWorkflowError.persistenceUnsafe }
            guard (values.fileSize ?? 0) <= AgentWorkflowLimits.maximumBodyBytes + 8_192 else {
                throw AgentWorkflowError.boundsExceeded("SKILL.md")
            }
            return await importWorkflowText(try String(contentsOf: url, encoding: .utf8), fallbackName: url.deletingPathExtension().lastPathComponent)
        } catch { workflowError = error.localizedDescription; return false }
    }

    func importWorkflowURL(_ rawValue: String) async -> Bool {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), let workflowService else {
            workflowError = AgentWorkflowError.insecureURL.localizedDescription
            return false
        }
        do { _ = try await workflowService.linkLiveSource(url); await reloadWorkflows(); return true }
        catch { workflowError = error.localizedDescription; return false }
    }

    func importPrivateSkillsAsWorkflows() async {
        guard let workflowService else { return }
        let records = Array(privateSkills.prefix(AgentWorkflowLimits.maximumWorkflows))
        var payloads: [AgentWorkflowSkillImportPayload] = []
        for record in records {
            do {
                let document = try await privateSkillLibrary.read(id: record.id)
                payloads.append(.init(
                    identifier: document.record.id,
                    name: document.record.name,
                    description: document.record.description,
                    skillMarkdown: document.body,
                    sourceReference: "private-skill:\(document.record.id)"
                ))
            } catch { workflowError = error.localizedDescription }
        }
        let result = await workflowService.portPrivateSkills(payloads)
        await reloadWorkflows()
        if !result.skipped.isEmpty { workflowError = result.skipped.map(\.reason).joined(separator: "\n") }
    }

    /// Maps only events that already passed the existing automation connector/webhook ingress.
    func dispatchWorkflowAuthenticatedEvent(_ event: AutomationEvent) async {
        let kind = event.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { return }
        let key = "connector:\(event.connectorID.uuidString.lowercased()):\(kind)"
        do { _ = try await workflowService?.dispatchEvent(key); await reloadWorkflows() }
        catch { workflowError = error.localizedDescription }
    }

    func setWorkflowRuntimeActive(_ active: Bool) {
        if active { startWorkflowScheduleCoordinator() }
        else { workflowScheduleTask?.cancel(); workflowScheduleTask = nil }
    }

    func runWorkflowScheduleTick(now: Date = .now) async {
        guard let workflowService else { return }
        let schedules = Set(workflows.compactMap { workflow -> String? in
            guard workflow.isEnabled, case .schedule(let expression) = workflow.trigger else { return nil }
            return expression
        })
        workflowNextRuns = workflowNextRuns.filter { schedules.contains($0.key) }
        for schedule in schedules.sorted() {
            if let due = workflowNextRuns[schedule], due <= now {
                do { _ = try await workflowService.dispatchSchedule(schedule) }
                catch { workflowError = error.localizedDescription }
                workflowNextRuns[schedule] = try? AutomationSchedule.nextRun(for: schedule, after: now, defaultTimeZone: workflowTimeZone)
            } else if workflowNextRuns[schedule] == nil {
                do { workflowNextRuns[schedule] = try AutomationSchedule.nextRun(for: schedule, after: now, defaultTimeZone: workflowTimeZone) }
                catch { workflowError = error.localizedDescription }
            }
        }
        workflowRuns = await workflowService.runs()
    }

    private var workflowTimeZone: TimeZone {
        settings.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private func reconcileWorkflowSchedules(now: Date) {
        let enabled = Set(workflows.compactMap { workflow -> String? in
            guard workflow.isEnabled, case .schedule(let value) = workflow.trigger else { return nil }
            return value
        })
        workflowNextRuns = workflowNextRuns.filter { enabled.contains($0.key) }
        for schedule in enabled where workflowNextRuns[schedule] == nil {
            workflowNextRuns[schedule] = try? AutomationSchedule.nextRun(for: schedule, after: now, defaultTimeZone: workflowTimeZone)
        }
    }

    func startWorkflowScheduleCoordinator() {
        guard workflowScheduleTask == nil else { return }
        workflowScheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runWorkflowScheduleTick()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }
}

struct AppWorkflowPromptExecutor: AgentWorkflowPromptExecuting {
    let registry: ProviderRegistry
    let agents: AgentService

    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String {
        guard let agentID = request.agentID,
              let profile = await agents.profile(id: agentID), profile.archivedAt == nil,
              let provider = await registry.provider(id: profile.providerID) else {
            throw ProviderError.transport("The workflow's selected agent or provider is unavailable.")
        }
        var userText = request.prompt
        if !request.priorOutputs.isEmpty {
            userText += "\n\nPrior workflow outputs:\n" + request.priorOutputs.joined(separator: "\n")
        }
        userText = Self.boundedUTF8(userText, maximumBytes: AgentWorkflowLimits.maximumBodyBytes)
        let messages = [
            ChatMessage(role: .system, text: profile.instructions),
            ChatMessage(role: .user, text: userText),
        ]
        let inference = InferenceRequest(conversationID: request.runID, modelID: profile.modelID, messages: messages)
        var output = ""
        for try await event in provider.stream(inference) {
            if case .textDelta(let delta) = event {
                guard output.utf8.count + delta.utf8.count <= AgentWorkflowLimits.maximumBodyBytes else {
                    throw AgentWorkflowError.boundsExceeded("prompt output")
                }
                output += delta
            }
        }
        return output
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.utf8.index(value.utf8.startIndex, offsetBy: maximumBytes)
        while end > value.utf8.startIndex,
              end < value.utf8.endIndex,
              value.utf8[end] & 0b1100_0000 == 0b1000_0000 {
            end = value.utf8.index(before: end)
        }
        return String(decoding: value.utf8[..<end], as: UTF8.self)
    }
}

/// Workflows cannot obtain user-effect authority until the app adds an explicit per-run consent UI.
struct AppWorkflowNoAuthorityActionHandler: AgentWorkflowActionHandling {
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String {
        throw AgentWorkflowError.actionDenied(request.action.rawValue)
    }
}
