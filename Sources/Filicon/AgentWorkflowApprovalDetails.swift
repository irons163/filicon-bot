import SwiftUI

struct AgentWorkflowApprovalDetails: View {
    let metadata: [String: String]
    static let disclosure = "This is a shared workflow, not private memory. All agents in this local workspace may reference it and send its body to their models. Existing and future routines or workflows may use the new body; renaming may break name-based references. Saving does not run or schedule anything, grant tools, or change permissions. Already running requests keep their captured content."
    static let referenceNotice = "Direct references are a snapshot, not the full affected audience; indirect and future references may also use this workflow. At most 100 direct references are listed."
    static let deletionDisclosure = "This permanently removes the shared workflow definition. There is no undo. Existing run history remains visible by workflow ID. Runs that already captured its content are not cancelled. Other workflows and routines stay unchanged, including their schedules; future references may fail or omit this content. Files, sources, connections and permissions are not removed or changed."

    private var isDeletion: Bool { metadata["agentWorkflowAction"] == "delete" }
    private var title: String {
        isDeletion ? "Delete reusable workflow" : metadata["agentWorkflowAction"] == "update" ? "Rewrite reusable workflow" : "Save reusable workflow"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FiliconLocalization.string(title)).font(.headline)
            Text(verbatim: metadata["agentName"] ?? "").font(.callout.weight(.semibold))
            Text(l10n("Workflow ID")).font(.caption.weight(.semibold))
            Text(verbatim: metadata["agentWorkflowID"] ?? "").font(.caption.monospaced())
            if metadata["agentWorkflowAction"] == "update" || isDeletion {
                Text(l10n("Current workflow")).font(.headline)
                definition(prefix: "previousAgentWorkflow")
                if !isDeletion { Divider() }
            }
            if !isDeletion {
                Text(l10n("Proposed workflow")).font(.headline)
                definition(prefix: "agentWorkflow")
            }
            Text(FiliconLocalization.string(isDeletion ? Self.deletionDisclosure : Self.disclosure)).font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            Text(l10n("Known direct references")).font(.caption.weight(.semibold))
            Text(verbatim: metadata["agentWorkflowReferenceCount"] ?? "0").font(.caption.monospaced())
            if let references = metadata["agentWorkflowReferences"], !references.isEmpty {
                Text(verbatim: references).font(.caption)
            }
            Text(FiliconLocalization.string(Self.referenceNotice)).font(.caption).foregroundStyle(FiliconTheme.textSecondary)
        }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func definition(prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: metadata[prefix + "Name"] ?? "").font(.callout.weight(.semibold))
            Text(l10n(metadata[prefix + "Enabled"] == "true" ? "Workflow enabled" : "Workflow disabled")).font(.caption)
            Text(l10n("Description")).font(.caption.weight(.semibold))
            Text(verbatim: metadata[prefix + "Description"] ?? "")
            Text(l10n("Full workflow body")).font(.caption.weight(.semibold))
            Text(verbatim: metadata[prefix + "Body"] ?? "").font(.callout)
        }
    }
}
