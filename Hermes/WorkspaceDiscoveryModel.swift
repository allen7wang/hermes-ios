import Foundation

extension AppModel {
    func workspaceSnapshot() throws -> WorkspaceDiscoverySnapshot {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        var drafts = try draftStore.snapshot().filter { $0.key.hasPrefix("\(activeProfileID.uuidString)/local/") }
        // Include current in-memory input even if its latest automatic write failed.
        drafts[draftKey] = draft
        return .init(profileID: activeProfileID, profileName: activeProfileName, projects: projects,
                     conversations: conversations, drafts: drafts)
    }

    func startWorkspaceConversation(profileID: UUID) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard profileID == activeProfileID else { throw WorkspaceError.changedContext }
        guard !isSending else { throw WorkspaceError.busy }
        guard newConversation() else { throw WorkspaceError.draftSaveFailed }
    }

    /// Resolve identifiers again at the moment of navigation; a result is not write authority.
    func openWorkspaceDestination(_ destination: WorkspaceDestination, profileID: UUID) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard profileID == activeProfileID else { throw WorkspaceError.changedContext }
        guard !isSending else { throw WorkspaceError.busy }
        var conversationID: UUID?
        switch destination {
        case .project(let id):
            guard projects.contains(where: { $0.id == id }) else { throw ProjectError.missing }
            return
        case .document(let projectID, let documentID):
            guard projects.first(where: { $0.id == projectID })?.documents.contains(where: { $0.id == documentID }) == true else { throw ProjectDocumentError.missing }
            return
        case .conversation(let id): conversationID = id
        case .message(let target):
            guard conversations.first(where: { $0.id == target.conversationID })?.messages.contains(where: { $0.id == target.messageID }) == true else { throw MessageLibraryError.missing }
            conversationID = target.conversationID
        case .draft(let id):
            let key = DraftStore.localKey(profileID: profileID, conversationID: id)
            let text = key == draftKey ? draft : draftStore.text(for: key)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.missing }
            conversationID = id
        }
        if let id = conversationID, !conversations.contains(where: { $0.id == id }) { throw WorkspaceError.missing }
        // Do not navigate away from an input whose persistence is currently failing.
        let opened = conversationID.map { select($0) } ?? newConversation()
        guard opened else { throw WorkspaceError.draftSaveFailed }
    }
}
