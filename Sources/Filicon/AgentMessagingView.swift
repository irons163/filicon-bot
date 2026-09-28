import SwiftUI
import FiliconAgents
import FiliconDomain
import FiliconAppServices
import UniformTypeIdentifiers

enum MailboxTimelineRow: Identifiable {
    case incoming(AgentMessage)
    case publication(AgentMessage, RoomMessage)
    var id: UUID {
        switch self {
        case .incoming(let message): message.id
        case .publication(_, let message): message.id
        }
    }
    static func rows(for messages: [AgentMessage]) -> [Self] {
        let rows = messages.flatMap { incoming in
            [Self.incoming(incoming)] + (incoming.delivery?.publications ?? []).map { Self.publication(incoming, $0) }
        }
        let counts = Dictionary(grouping: rows, by: \.id).mapValues(\.count)
        return rows.filter { counts[$0.id] == 1 }
    }
}

struct AgentMessagingView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var senderID: UUID?
    @State private var recipientID: UUID?
    @State private var draft = ""
    @State private var priority = AgentMessagePriority.normal
    @State private var mailbox = Mailbox.thread
    @State private var feedback: String?
    @State private var images: [AttachmentMetadata] = []
    @State private var importing = false
    @State private var sending = false
    @State private var referenceTargetID: UUID?
    @State private var referenceRequestID = UUID()

    private enum Mailbox: String, CaseIterable, Identifiable {
        case thread = "Thread"
        case inbox = "Inbox"
        case outbox = "Outbox"
        var id: Self { self }
        var title: String { agentMessageString(rawValue) }
    }

    private var activeAgents: [AgentProfile] {
        model.agents.filter { $0.archivedAt == nil }
    }

    private var visibleMessages: [AgentMessage] {
        switch mailbox {
        case .thread:
            guard let senderID, let recipientID else { return [] }
            return model.agentThread(between: senderID, and: recipientID)
        case .inbox:
            guard let recipientID else { return [] }
            return model.agentInbox(for: recipientID)
        case .outbox:
            guard let senderID else { return [] }
            return model.agentOutbox(for: senderID)
        }
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            controls
            Divider()
            if !model.runningAgentMessageScopes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.runningAgentMessageScopes.sorted { $0.uuidString < $1.uuidString }, id: \.self) { scopeID in
                            HStack {
                                ProgressView().controlSize(.small)
                                if let message = model.agentMessages.first(where: { $0.delivery?.originConversationID == scopeID }) {
                                    Text("\(agentName(message.senderID)) → \(agentName(message.recipientID))")
                                }
                                Text(agentMessageString("Running"))
                                Spacer()
                                Button(agentMessageString("Stop")) { Task { await model.stopAgentMessages(scopeID: scopeID) } }
                            }
                            WorkspaceFolderAccessPanel(conversationID: scopeID)
                            GroupToolApprovalPanel(groupID: scopeID)
                            MCPApprovalPanel(conversationID: scopeID)
                        }
                    }.padding()
                }.frame(maxHeight: 300)
            }
            if activeAgents.count < 2 {
                ContentUnavailableView(
                    agentMessageString("Two active agents required"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(agentMessageString("Create or restore another agent to exchange messages."))
                )
            } else if visibleMessages.isEmpty {
                ContentUnavailableView(agentMessageString("No messages"), systemImage: "tray", description: Text(emptyDescription))
            } else {
                ScrollViewReader { proxy in
                    List(MailboxTimelineRow.rows(for: visibleMessages)) { row in
                        Group {
                            switch row {
                            case .incoming(let message): messageRow(message)
                            case .publication(let incoming, let publication): publishedResponse(publication, incoming: incoming)
                            }
                        }
                        .id(row.id)
                        .listRowBackground(referenceTargetID == row.id ? FiliconTheme.input : Color.clear)
                    }
                    .onChange(of: referenceRequestID) { _, _ in
                        if let referenceTargetID { withAnimation { proxy.scrollTo(referenceTargetID, anchor: .center) } }
                    }
                }
            }
        }
        .background(FiliconTheme.canvas)
        .task {
            normalizeSelection()
            await model.reloadAgentMessages()
        }
        .onChange(of: model.agents) { _, _ in normalizeSelection() }
        .onChange(of: senderID) { _, _ in normalizeSelection() }
        .onChange(of: senderID) { _, _ in referenceSelectionChanged() }
        .onChange(of: recipientID) { _, _ in referenceSelectionChanged() }
        .onChange(of: mailbox) { _, _ in referenceSelectionChanged() }
        .onChange(of: model.settings.accountScope) { _, _ in referenceSelectionChanged() }
        .onChange(of: model.settings.accountScope) { _, _ in images.removeAll() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(agentMessageString("From"), selection: $senderID) {
                    Text(agentMessageString("Select sender")).tag(Optional<UUID>.none)
                    ForEach(activeAgents) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(agentMessageString("To"), selection: $recipientID) {
                    Text(agentMessageString("Select recipient")).tag(Optional<UUID>.none)
                    ForEach(activeAgents.filter { $0.id != senderID }) { profile in
                        Text(recipientLabel(profile)).tag(Optional(profile.id))
                    }
                }
                Picker(agentMessageString("Priority"), selection: $priority) {
                    Text(agentMessageString("Normal")).tag(AgentMessagePriority.normal)
                    Text(agentMessageString("Priority")).tag(AgentMessagePriority.priority)
                }
                .frame(width: 150)
            }
            if priority == .priority { AgentPriorityMessageNotice() }
            HStack {
                Button(l10n("Attach images…"), systemImage: "photo.on.rectangle") { Task { await attachImagesButtonTapped() } }
                    .disabled(importing || sending)
                if importing { ProgressView().controlSize(.small) }
                Text(l10n("PNG/JPEG only · up to 4 images · 5 MB each · 12 MB total"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !images.isEmpty {
                Text(l10n("Images will be sent to the selected recipient's configured model."))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { AgentMessageImagePreviews(images: images) }.frame(maxHeight: 200)
                Button(l10n("Remove images")) { images.removeAll() }.disabled(sending)
            }
            HStack(alignment: .bottom) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: draft) { _, value in
                        if value.count > 8_000 { draft = String(value.prefix(8_000)) }
                    }
                VStack(alignment: .trailing) {
                    Text("\(draft.count)/8,000").font(.caption).foregroundStyle(.secondary)
                    Button(agentMessageString("Send")) { send() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSend)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker(agentMessageString("Mailbox"), selection: $mailbox) {
                    ForEach(Mailbox.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    if let recipientID, model.agentMessageUnreadCounts[recipientID, default: 0] > 0 {
                        Button(agentMessageString("Mark Inbox Read")) {
                            Task { await model.markAgentMessagesRead(recipientID: recipientID) }
                        }
                    }
                    Spacer()
                    if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding()
    }

    private func messageRow(_ message: AgentMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.deliveredAt == nil ? "envelope.badge" : "envelope.open")
                .foregroundStyle(message.deliveredAt == nil ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(agentName(message.senderID)) → \(agentName(message.recipientID))").fontWeight(.medium)
                    if message.priority == .priority { Label(agentMessageString("Priority"), systemImage: "exclamationmark").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.text).textSelection(.enabled)
                if let images = message.images { AgentMessageImagePreviews(images: images) }
                if let delivery = message.delivery {
                    Text(deliveryTitle(delivery.state)).font(.caption).foregroundStyle(.secondary)
                    if (delivery.publications ?? []).isEmpty, let response = delivery.response, !response.isEmpty, response.uppercased() != "PASS" {
                        Text((delivery.state == .cancelled && response == AgentExecutionSuperseded().localizedDescription)
                             || AgentImageError(rawValue: response) != nil
                             ? FiliconLocalization.string(response) : response).font(.callout).textSelection(.enabled)
                    }
                }
            }
            Button(agentMessageString("Reply")) {
                senderID = message.recipientID
                recipientID = message.senderID
                mailbox = .thread
                feedback = l10n("\(agentMessageString("Replying as")) \(agentName(message.recipientID)).")
            }
            .buttonStyle(.borderless)
            .disabled(!activeAgents.contains(where: { $0.id == message.senderID })
                      || !activeAgents.contains(where: { $0.id == message.recipientID }))
        }
        .padding(.vertical, 3)
    }

    private func publishedResponse(_ publication: RoomMessage, incoming: AgentMessage) -> some View {
        AgentPublishedResponses(publications: [publication],
            replySource: { model.mailboxMessageReferences.quotedTarget(from: $0.id, replyingTo: incoming.id)?.message },
            replyAuthor: { $0.senderID.map(agentName) ?? l10n("You") },
            references: { message in
                .init(target: { model.mailboxMessageReferences.target(for: $0, from: message.id, replyingTo: incoming.id)?.message.id },
                      show: { referenceLinkTapped(target: $0, publication: message, incoming: incoming) })
            },
            onShowReply: { quoteButtonTapped(publication: $0, incoming: incoming) },
            canAnswer: { model.canAnswerMailboxQuestion(incoming, publication: $0) },
            onAnswer: { message, answer in
                Task { await model.answerMailboxQuestion(incomingID: incoming.id, publicationID: message.id, answer: answer) }
            }, secretModel: { model.mailboxSecretCards[$0.id] },
            secretEnabled: { model.canUseMailboxSecret(incoming, publication: $0) },
            onOpenFile: { message, file in model.openMailboxMessageFile(file, messageID: message.id, incomingID: incoming.id) },
            onPreviewRemote: { message, reference, review in
                try await model.previewRemoteAttachment(reference, at: .mailbox(incoming.id, message.id), approveRedirect: review)
            })
    }

    private func referenceLinkTapped(target: UUID, publication: RoomMessage, incoming: AgentMessage) {
        // Revalidate against the current snapshot rather than a stale rendered link.
        guard let destination = model.mailboxMessageReferences.referenceTarget(target, from: publication.id, replyingTo: incoming.id) else { return }
        showReference(destination)
    }

    private func showReference(_ destination: MailboxMessageReferences.Destination) {
        model.revealMailboxIncoming(destination.incoming)
        referenceTargetID = destination.message.id
        referenceRequestID = UUID()
    }

    private func quoteButtonTapped(publication: RoomMessage, incoming: AgentMessage) {
        guard let destination = model.mailboxMessageReferences.quotedTarget(from: publication.id, replyingTo: incoming.id) else { return }
        showReference(destination)
    }

    private func referenceSelectionChanged() {
        referenceTargetID = nil
        model.clearRevealedMailboxIncoming()
    }

    private var canSend: Bool {
        guard let senderID, let recipientID else { return false }
        return !importing && !sending && senderID != recipientID && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func deliveryTitle(_ state: AgentMessageDelivery.State) -> String {
        switch state {
        case .queued: agentMessageString("Queued")
        case .running: agentMessageString("Running")
        case .completed: agentMessageString("Completed")
        case .failed: agentMessageString("Failed")
        case .cancelled: agentMessageString("Cancelled")
        }
    }

    private var emptyDescription: String {
        switch mailbox {
        case .thread: agentMessageString("Send the first message between the selected agents.")
        case .inbox: agentMessageString("The selected recipient has no messages.")
        case .outbox: agentMessageString("The selected sender has not sent any messages.")
        }
    }

    private func recipientLabel(_ profile: AgentProfile) -> String {
        let unread = model.agentMessageUnreadCounts[profile.id, default: 0]
        return unread == 0 ? profile.name : "\(profile.name) (\(unread) \(agentMessageString("unread")))"
    }

    private func agentName(_ id: UUID) -> String {
        model.agents.first(where: { $0.id == id })?.name ?? agentMessageString("Unknown agent")
    }

    private func normalizeSelection() {
        let ids = Set(activeAgents.map(\.id))
        if senderID.map({ !ids.contains($0) }) ?? true { senderID = activeAgents.first?.id }
        if recipientID.map({ !ids.contains($0) || $0 == senderID }) ?? true {
            recipientID = activeAgents.first(where: { $0.id != senderID })?.id
        }
    }

    private func send() {
        guard canSend, let senderID, let recipientID else { return }
        let message = draft
        let selectedImages = images
        let selectedPriority = priority
        sending = true
        feedback = nil
        Task {
            defer { sending = false }
            if await model.sendAgentMessage(senderID: senderID, recipientID: recipientID, text: message, priority: selectedPriority, images: selectedImages) {
                if draft == message { draft = "" }
                images.removeAll()
                feedback = agentMessageString("Queued")
                mailbox = .thread
            } else {
                feedback = agentMessageString("Not sent. You can edit and retry.")
            }
        }
    }

    private func attachImagesButtonTapped() async {
        importing = true
        defer { importing = false }
        let accountScope = model.settings.accountScope
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard await panel.begin() == .OK, accountScope == model.settings.accountScope else { return }
        do { images = try await model.importAgentMessageImages(panel.urls); feedback = nil }
        catch is CancellationError {}
        catch { feedback = FiliconLocalization.string(error.localizedDescription) }
    }
}

struct AgentPublishedResponses: View {
    let publications: [RoomMessage]
    var replySource: (RoomMessage) -> RoomMessage? = { _ in nil }
    var replyAuthor: (RoomMessage) -> String = { _ in "" }
    var references: (RoomMessage) -> RichMarkdownMessageReferences? = { _ in nil }
    var onShowReply: ((RoomMessage) -> Void)?
    var canAnswer: (RoomMessage) -> Bool = { _ in false }
    var onAnswer: (RoomMessage, AgentQuestionAnswer) -> Void = { _, _ in }
    var secretModel: (RoomMessage) -> AgentSecretRequestCardModel? = { _ in nil }
    var secretEnabled: (RoomMessage) -> Bool = { _ in false }
    var onOpenFile: ((RoomMessage, AttachmentMetadata) -> Void)?
    var onPreviewRemote: ((RoomMessage, RemoteAttachmentReference, @escaping RemoteRedirectReview) async throws -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(l10n("Published response"), systemImage: "bubble.left.and.text.bubble.right").font(.caption).foregroundStyle(.secondary)
            ForEach(publications) { publication in
                VStack(alignment: .leading, spacing: 6) {
                    if publication.replyToMessageID != nil {
                        MailboxReplyPreview(original: replySource(publication), author: replySource(publication).map(replyAuthor) ?? "",
                            onOpen: onShowReply.map { show in { show(publication) } })
                    }
                    if let secret = publication.secretRequest {
                        if let model = secretModel(publication) {
                            AgentSecretRequestCard(model: model).disabled(!secretEnabled(publication))
                        } else {
                            Label(l10n("Secure credential request"), systemImage: "lock.shield")
                            Text(secret.request.label)
                            Text(FiliconLocalization.string(secret.state == .stored
                                ? "Credential stored. Remote authentication has not been verified."
                                : "This credential request is no longer available."))
                                .font(.caption)
                        }
                    } else if let question = publication.question {
                        GroupQuestionCard(card: question, enabled: canAnswer(publication)) { answer in
                            onAnswer(publication, answer)
                        }
                    } else if let reference = publication.cursorAgent {
                        CursorAgentReferenceCard(reference: reference)
                    } else if !publication.text.isEmpty {
                        RichMarkdownView(source: publication.text, messageReferences: references(publication))
                    }
                    if let images = publication.images, !images.isEmpty { AgentMessageImagePreviews(images: images) }
                    if let gallery = publication.remoteImages {
                        RemoteImageGalleryView(gallery: gallery, onPreview: onPreviewRemote.map { action in
                            { reference, review in try await action(publication, reference, review) }
                        })
                    }
                    if let reference = publication.remoteAttachment {
                        RemoteAttachmentCard(reference: reference, onPreview: onPreviewRemote.map { action in { review in try await action(publication, reference, review) } })
                    }
                    ForEach(publication.files ?? []) { file in
                        Button { onOpenFile?(publication, file) } label: {
                            HStack {
                                Image(systemName: "doc")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: file.filename).lineLimit(2)
                                    if let alt = file.altText {
                                        Text(verbatim: alt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "eye")
                            }
                        }
                        .buttonStyle(.borderless).disabled(onOpenFile == nil)
                        .accessibilityIdentifier("mailbox-file-\(file.id)")
                        .help(file.altText ?? file.filename)
                    }
                }
            }
        }
    }
}

struct MailboxReplyPreview: View {
    let original: RoomMessage?
    let author: String
    var onOpen: (() -> Void)?
    var body: some View {
        Group {
            if let original {
                if let onOpen {
                    Button(l10n("View original message"), systemImage: "arrow.up.backward", action: onOpen)
                        .buttonStyle(.borderless).font(.caption)
                        .accessibilityIdentifier("mailbox-show-original")
                }
                DisclosureGroup {
                    Text(verbatim: original.text).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let images = original.images, !images.isEmpty { AgentMessageImagePreviews(images: images) }
                    if let remote = original.remoteAttachment { RemoteAttachmentCard(reference: remote) }
                    if let gallery = original.remoteImages { RemoteImageGalleryView(gallery: gallery) }
                    ForEach(original.files ?? []) { file in
                        Label(file.filename, systemImage: "doc").font(.caption)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(l10n("Replying to"), systemImage: "arrowshape.turn.up.left").font(.caption2)
                        Text(verbatim: author).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(verbatim: original.text.isEmpty
                            ? original.remoteAttachment?.replyPreviewText ?? original.files?.first?.filename ?? (!(original.images ?? []).isEmpty ? l10n("Image") : "")
                            : String(original.text.prefix(240)))
                            .font(.caption).lineLimit(3)
                    }
                }
            } else {
                Label(l10n("Original message unavailable"), systemImage: "arrowshape.turn.up.left").font(.caption)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mailbox-reply-preview")
    }
}

/// Reused by the draft, durable mailbox, and exact-payload approval card.
struct AgentMessageImagePreviews: View {
    @EnvironmentObject private var model: AppModel
    let images: [AttachmentMetadata]
    var compact = false
    var body: some View {
        AgentMessageImageGallery(images: images) { image in
            AgentMessageImagePreview(image: image, compact: compact, expanded: images.count == 1,
                                     onOpen: { model.openAgentMessageImage(image, gallery: images) })
        }
    }
}

struct AgentMessageImageGallery<Content: View>: View {
    let images: [AttachmentMetadata]
    @ViewBuilder var content: (AttachmentMetadata) -> Content

    var body: some View {
        if images.count == 1, let image = images.first {
            content(image)
        } else if !images.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(images) { image in content(image) }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

private struct AgentMessageImagePreview: View {
    @EnvironmentObject private var model: AppModel
    let image: AttachmentMetadata
    var compact = false
    var expanded = false
    let onOpen: () -> Void
    @State private var preview: NSImage?
    @State private var failed = false
    var body: some View {
        AgentMessageImagePreviewContent(image: image, preview: preview, failed: failed, compact: compact, expanded: expanded,
                                       onOpen: onOpen)
            .task(id: "\(model.settings.accountScope ?? "local"):\(image.id)") { await loadPreview() }
    }
    private func loadPreview() async {
        preview = nil; failed = false
        do {
            let bytes = try await model.agentMessageImageData(image)
            try Task.checkCancellation()
            preview = NSImage(data: bytes); failed = preview == nil
        } catch is CancellationError {} catch { failed = true }
    }
}

struct AgentMessageImagePreviewContent: View {
    let image: AttachmentMetadata
    let preview: NSImage?
    var failed = false
    var compact = false
    var expanded = false
    var onOpen: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preview {
                if let onOpen {
                    Button(action: onOpen) { fittedImage(preview) }
                        .buttonStyle(.plain)
                        .help(image.altText ?? image.filename)
                } else {
                    fittedImage(preview)
                }
            } else if failed { Text(l10n("Image preview unavailable")).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
            Text(verbatim: image.filename).font(.caption).textSelection(.enabled)
            if let alt = image.altText {
                Text(verbatim: alt).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                Text(verbatim: image.id).font(.caption2.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: expanded ? 560 : 280, alignment: .leading)
    }

    private func fittedImage(_ preview: NSImage) -> some View {
        AgentImageFitLayout(imageSize: preview.size, maximumWidth: expanded ? 560 : 280,
                            maximumHeight: compact ? 96 : expanded ? 320 : 160) {
            Image(nsImage: preview).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(image.altText ?? image.filename)
        }
    }
}

/// Negotiate both dimensions together, so a tall proposal cannot make the
/// scaled image draw outside a narrower chat bubble or gallery cell.
private struct AgentImageFitLayout: Layout {
    let imageSize: CGSize
    let maximumWidth: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let ratio = imageSize.width / imageSize.height
        let width = max(0, min(proposal.width ?? maximumWidth, maximumWidth, maximumHeight * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private func agentMessageString(_ key: String) -> String {
    FiliconLocalization.string(key)
}
