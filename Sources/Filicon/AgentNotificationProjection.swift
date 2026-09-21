import Foundation
import FiliconAgents
import FiliconAppServices

enum AgentNotificationProjection {
    static func notificationSnapshots(
        profiles: [AgentProfile],
        tasks: [AgentAsyncTask]
    ) -> [AgentNotificationSnapshot] {
        let latestTasks = latestTaskByAgent(tasks)
        return profiles.map { profile in
            let task = latestTasks[profile.id]
            let isRunning = profile.status == .running || task?.status.isInFlight == true
            let awaitingReason: String? = if profile.status == .awaitingInput || task?.status == .awaitingInput {
                task.map { "\($0.title) is waiting for your input." } ?? "Waiting for your input."
            } else {
                nil
            }
            let terminalMessageID = task.flatMap { task -> String? in
                task.status.isInFlight ? nil : task.id.uuidString.lowercased()
            }
            let terminalPreview = task.flatMap { task -> String? in
                guard !task.status.isInFlight else { return nil }
                let value = task.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : String(value.prefix(2_048))
            }
            return AgentNotificationSnapshot(
                id: profile.id.uuidString.lowercased(),
                name: profile.name,
                isRunning: isRunning,
                awaitingReason: awaitingReason,
                notifyEnabled: profile.notifyOnAgentUpdates,
                isHidden: profile.archivedAt != nil,
                lastMessageID: terminalMessageID,
                lastMessagePreview: terminalPreview
            )
        }
    }

    static func dockSnapshots(
        profiles: [AgentProfile],
        tasks: [AgentAsyncTask]
    ) -> [DockBadgeAgentSnapshot] {
        let latestTasks = latestTaskByAgent(tasks)
        return profiles.map { profile in
            let taskDate = latestTasks[profile.id].map { $0.finishedAt ?? $0.startedAt }
            let date = max(profile.updatedAt, taskDate ?? .distantPast)
            return DockBadgeAgentSnapshot(
                id: profile.id.uuidString.lowercased(),
                hasUnread: profile.unreadCount > 0,
                unreadCount: profile.unreadCount,
                isHidden: profile.archivedAt != nil,
                epoch: "agent-roster-v1",
                sequence: monotonicSequence(date)
            )
        }
    }

    private static func latestTaskByAgent(_ tasks: [AgentAsyncTask]) -> [UUID: AgentAsyncTask] {
        tasks.reduce(into: [:]) { result, task in
            guard let previous = result[task.agentID] else {
                result[task.agentID] = task
                return
            }
            let previousDate = previous.finishedAt ?? previous.startedAt
            let candidateDate = task.finishedAt ?? task.startedAt
            if candidateDate > previousDate || (candidateDate == previousDate && task.id.uuidString > previous.id.uuidString) {
                result[task.agentID] = task
            }
        }
    }

    private static func monotonicSequence(_ date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return UInt64(min(milliseconds, Double(UInt64.max)))
    }
}
