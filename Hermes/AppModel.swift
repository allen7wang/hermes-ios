import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState {
        case unconfigured
        case checking
        case connected
        case offline
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var trashedConversations: [Conversation] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isSending = false
    @Published private(set) var streamedReply = ""
    @Published private(set) var toolStatus: String?
    @Published var errorMessage: String?
    @Published private(set) var settings: ConnectionSettings
    @Published private(set) var profiles: [ConnectionProfile]
    @Published private(set) var activeProfileID: UUID
    @Published var draft = "" {
        didSet {
            guard !draftAlreadyPersisted else { return }
            do { try draftStore.set(draft, for: draftKey) }
            catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
        }
    }
    @Published private(set) var connectionState: ConnectionState = .unconfigured

    private var activeTask: Task<Void, Never>?
    private let conversationsURL: URL
    private let directory: URL
    private let recoveryProfileID = UUID()
    private let installationID: UUID
    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private let sessionConfiguration: URLSessionConfiguration
    private var storageLoadFailed = false
    private var draftAlreadyPersisted = false
    private var allConversations: [Conversation] = []
    private var selectedConversations: [String: String] = [:]
    let draftStore: DraftStore

    var activeProfileName: String { profiles.first { $0.id == activeProfileID }?.name ?? "Hermes" }
    var projects: [LocalProject] {
        (profiles.first { $0.id == activeProfileID }?.projects ?? []).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }
    var currentProject: LocalProject? { selectedConversation.flatMap { project(for: $0) } }
    var currentReferenceDocuments: [ProjectDocument] {
        guard !needsRecovery else { return [] }
        return (try? ProjectDocument.selected(ids: selectedConversation?.referenceDocumentIDs ?? [], from: currentProject)) ?? []
    }

    func project(for conversation: Conversation) -> LocalProject? {
        guard let projectID = conversation.projectID else { return nil }
        return profiles.first { $0.id == conversation.profileID }?.projects.first { $0.id == projectID }
    }
    var draftKey: String { DraftStore.localKey(profileID: activeProfileID, conversationID: selectedID) }

    var needsRecovery: Bool { storageLoadFailed || !draftStore.isReadable }

    var attachmentDirectory: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    var conversationConfiguration: ConversationConfiguration {
        if let conversation = selectedConversation { return conversation.workspaceState.configuration }
        return profiles.first { $0.id == activeProfileID }?.conversationDefaults ?? ConversationConfiguration()
    }

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         credentials: CredentialStore = SystemCredentialStore(),
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.defaults = defaults
        self.credentials = credentials
        self.sessionConfiguration = sessionConfiguration
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        conversationsURL = directory.appendingPathComponent("conversations.json")
        let installation = defaults.string(forKey: "installationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        installationID = installation
        defaults.set(installation.uuidString, forKey: "installationID")
        var recoveryError: Error?
        do { try BackupRestoreTransaction.recover(directory: directory, defaults: defaults) }
        catch { recoveryError = error }
        draftStore = DraftStore(directory: directory)

        let libraryURL = directory.appendingPathComponent("connections.json")
        let libraryFileExists = FileManager.default.fileExists(atPath: libraryURL.path)
        let libraryData = libraryFileExists ? try? Data(contentsOf: libraryURL) : defaults.data(forKey: "connectionLibrary")
        let library = libraryData.flatMap { try? JSONDecoder().decode(ConnectionLibrary.self, from: $0) }
        let legacy = ConnectionProfile(id: ConnectionProfile.legacyID, name: "默认连接",
                                       serverURL: defaults.string(forKey: "serverURL") ?? "",
                                       model: defaults.string(forKey: "model") ?? "hermes-agent")
        let savedProfiles = library?.profiles.isEmpty == false ? library!.profiles : [legacy]
        profiles = savedProfiles
        let active = savedProfiles.first { $0.id == library?.activeID } ?? savedProfiles[0]
        activeProfileID = active.id
        settings = active.settings(apiKey: credentials.read(account: active.credentialAccount))
        selectedConversations = library?.selectedConversations ?? [:]
        connectionState = settings.isConfigured ? .checking : .unconfigured
        if recoveryError != nil || (libraryFileExists && libraryData == nil) ||
            (libraryData != nil && (library == nil || library!.profiles.isEmpty)) {
            storageLoadFailed = true
            errorMessage = ProfileError.storageUnavailable.localizedDescription
        }
        do {
            for profile in savedProfiles {
                try PromptTemplate.validateCollection(profile.templates)
                try LocalProject.validateCollection(profile.projects)
                if let value = profile.conversationDefaults, try value.validated() != value { throw WorkspaceError.invalidConfiguration }
            }
        }
        catch { storageLoadFailed = true; errorMessage = ProfileError.storageUnavailable.localizedDescription }
        if FileManager.default.fileExists(atPath: conversationsURL.path) {
            do {
                let saved = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: conversationsURL))
                allConversations = saved.map { conversation in
                    var migrated = conversation
                    if migrated.profileID == nil { migrated.profileID = savedProfiles[0].id }
                    return migrated
                }
                for conversation in allConversations {
                    try conversation.workspaceState.validate()
                    let project = savedProfiles.first(where: { $0.id == conversation.profileID })?.projects.first { $0.id == conversation.projectID }
                    if conversation.projectID != nil && project == nil { throw ProjectError.missing }
                    _ = try ProjectDocument.selected(ids: conversation.referenceDocumentIDs ?? [], from: project)
                }
            } catch {
                storageLoadFailed = true
                errorMessage = "本机对话文件无法读取，已保留原文件。请先恢复备份再发送消息。"
            }
        }
        refreshConversations()
        restoreSelection()
        draft = draftStore.text(for: draftKey)
        persistLibrary()
        persist()
    }

    /// A changed endpoint creates a new profile so existing history keeps its original destination.
    @discardableResult
    func saveProfile(id: UUID?, name: String, connection: ConnectionSettings) throws -> UUID {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        let root = try HermesClient(settings: connection).rootURL
        guard !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.missingKey
        }
        let existing = profiles.first { $0.id == id }
        let oldRoot = existing.flatMap { try? HermesClient(settings: $0.settings(apiKey: "")).rootURL }
        let keepsIdentity = existing != nil && (existing!.serverURL.isEmpty || oldRoot == root)
        let profile = ConnectionProfile(
            id: keepsIdentity ? existing!.id : UUID(),
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            serverURL: connection.serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "hermes-agent" : connection.model.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTemplates: keepsIdentity ? existing?.promptTemplates : nil,
            conversationDefaults: keepsIdentity ? existing?.conversationDefaults : nil,
            localProjects: keepsIdentity ? existing?.localProjects : nil
        )
        guard !profile.name.isEmpty else { throw ProfileError.missingName }
        try draftStore.set(draft, for: draftKey)
        try credentials.save(connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.credentialAccount)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        activate(profile)
        return profile.id
    }

    func key(for id: UUID) -> String {
        guard let profile = profiles.first(where: { $0.id == id }) else { return "" }
        return credentials.read(account: profile.credentialAccount)
    }

    @discardableResult
    func selectProfile(_ id: UUID) -> Bool {
        guard !isSending, let profile = profiles.first(where: { $0.id == id }) else { return false }
        guard id != activeProfileID else { return true }
        guard preserveCurrentDraft() else { return false }
        activate(profile)
        return true
    }

    func removeProfile(_ id: UUID) throws {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try credentials.save("", account: profile.credentialAccount)
        try draftStore.remove(profileID: id)
        let removedImages = Set(allConversations.filter({ $0.profileID == id }).flatMap({ $0.messages.compactMap(\.imageID) }))
        allConversations.removeAll { $0.profileID == id }
        removeUnusedImages(removedImages)
        profiles.removeAll { $0.id == id }
        selectedConversations[id.uuidString] = nil
        if profiles.isEmpty { profiles = [ConnectionProfile(name: "默认连接", serverURL: "", model: "hermes-agent")] }
        if activeProfileID == id { activate(profiles[0]) }
        else { persistLibrary(); refreshConversations() }
        persist()
    }

    private func activate(_ profile: ConnectionProfile) {
        activeProfileID = profile.id
        settings = profile.settings(apiKey: credentials.read(account: profile.credentialAccount))
        connectionState = settings.isConfigured ? .checking : .unconfigured
        errorMessage = nil
        refreshConversations()
        restoreSelection()
        draft = draftStore.text(for: draftKey)
        persistLibrary()
    }

    private func restoreSelection() {
        if let saved = selectedConversations[activeProfileID.uuidString] {
            selectedID = conversations.first { $0.id.uuidString == saved }?.id
        } else { selectedID = conversations.first?.id }
    }

    private func rememberSelection() {
        selectedConversations[activeProfileID.uuidString] = selectedID?.uuidString ?? ""
        persistLibrary()
        draft = draftStore.text(for: draftKey)
    }

    private func persistLibrary() {
        guard !storageLoadFailed else { return }
        let library = ConnectionLibrary(profiles: profiles, activeID: activeProfileID,
                                        selectedConversations: selectedConversations)
        do {
            let data = try JSONEncoder().encode(library)
            try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
            defaults.set(data, forKey: "connectionLibrary")
        } catch { errorMessage = "连接保存失败：\(error.localizedDescription)" }
    }

    private func requireProjectAccess(profileID: UUID) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard !isSending else { throw WorkspaceError.busy }
        guard activeProfileID == profileID, profiles.contains(where: { $0.id == profileID }) else { throw ProjectError.changedContext }
    }

    @discardableResult
    func saveProject(id: UUID?, name: String, summary: String, instructions: String, profileID: UUID) throws -> UUID {
        try requireProjectAccess(profileID: profileID)
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }) else { throw ProjectError.changedContext }
        var candidate = profiles
        var projects = candidate[profileIndex].projects
        let existing = id.flatMap { id in projects.first { $0.id == id } }
        if id != nil && existing == nil { throw ProjectError.missing }
        guard existing != nil || projects.count < LocalProject.collectionLimit else { throw ProjectError.limit }
        let now = Date()
        let project = try LocalProject(id: existing?.id ?? UUID(), name: name, summary: summary, instructions: instructions,
            createdAt: existing?.createdAt ?? now, updatedAt: now, knowledgeDocuments: existing?.knowledgeDocuments).validated()
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.append(project) }
        try LocalProject.validateCollection(projects)
        candidate[profileIndex].projects = projects
        let library = ConnectionLibrary(profiles: candidate, activeID: activeProfileID, selectedConversations: selectedConversations)
        let data = try JSONEncoder().encode(library)
        try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        defaults.set(data, forKey: "connectionLibrary")
        profiles = candidate
        return project.id
    }

    @discardableResult
    func saveProjectDocument(id: UUID?, projectID: UUID, title: String, body: String, profileID: UUID,
                             expectedDocument: ProjectDocument? = nil) throws -> UUID {
        try requireProjectAccess(profileID: profileID)
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let projectIndex = profiles[profileIndex].projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.missing }
        var candidate = profiles
        var projects = candidate[profileIndex].projects
        var project = projects[projectIndex]
        var documents = project.documents
        let existing = id.flatMap { id in documents.first { $0.id == id } }
        if id != nil && existing == nil { throw ProjectDocumentError.missing }
        if let expectedDocument, existing != expectedDocument { throw ProjectDocumentError.changedDocument }
        let now = Date()
        let document = try ProjectDocument(id: existing?.id ?? UUID(), title: title, body: body,
            createdAt: existing?.createdAt ?? now, updatedAt: now).validated()
        if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = document }
        else { documents.append(document) }
        try ProjectDocument.validateCollection(documents)
        project.documents = documents
        project.updatedAt = now
        // An edited document must not invalidate a saved conversation, including one in the trash.
        for conversation in allConversations where conversation.profileID == profileID && conversation.projectID == projectID {
            do { _ = try ProjectDocument.selected(ids: conversation.referenceDocumentIDs ?? [], from: project) }
            catch ProjectDocumentError.selectionTooLarge { throw ProjectDocumentError.referencedSelectionTooLarge }
        }
        projects[projectIndex] = project
        candidate[profileIndex].projects = projects
        try commitProjectProfiles(candidate)
        return document.id
    }

    func deleteProjectDocument(_ id: UUID, projectID: UUID, profileID: UUID) throws {
        try requireProjectAccess(profileID: profileID)
        guard let project = projects.first(where: { $0.id == projectID }),
              let document = project.documents.first(where: { $0.id == id }) else { throw ProjectDocumentError.missing }
        try deleteProjectDocuments([document], projectID: projectID, profileID: profileID)
    }

    @discardableResult
    func copyProjectDocuments(_ documents: [ProjectDocument], fromProject sourceID: UUID,
                              toProject targetID: UUID, profileID: UUID) throws -> [UUID] {
        try requireProjectAccess(profileID: profileID)
        guard sourceID != targetID else { throw ProjectDocumentBatchError.sameProject }
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let source = profiles[profileIndex].projects.first(where: { $0.id == sourceID }),
              let targetIndex = profiles[profileIndex].projects.firstIndex(where: { $0.id == targetID }) else { throw ProjectError.missing }
        try ProjectDocumentBatch.validate(documents, in: source)
        var candidate = profiles
        var projects = candidate[profileIndex].projects
        try ProjectDocumentBatch.validateCapacity(documents, target: projects[targetIndex])
        let now = Date()
        let copies = documents.map { ProjectDocument(title: $0.title, body: $0.body, createdAt: now, updatedAt: now) }
        projects[targetIndex].documents += copies
        projects[targetIndex].updatedAt = now
        try LocalProject.validateCollection(projects)
        candidate[profileIndex].projects = projects
        try commitProjectProfiles(candidate)
        return copies.map(\.id)
    }

    func deleteProjectDocuments(_ snapshots: [ProjectDocument], projectID: UUID, profileID: UUID) throws {
        try requireProjectAccess(profileID: profileID)
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              let projectIndex = profiles[profileIndex].projects.firstIndex(where: { $0.id == projectID }) else { throw ProjectError.missing }
        var candidateProfiles = profiles
        var projects = candidateProfiles[profileIndex].projects
        try ProjectDocumentBatch.validate(snapshots, in: projects[projectIndex])
        let ids = Set(snapshots.map(\.id))
        var documents = projects[projectIndex].documents
        documents.removeAll { ids.contains($0.id) }
        projects[projectIndex].documents = documents
        projects[projectIndex].updatedAt = Date()
        candidateProfiles[profileIndex].projects = projects
        var candidateConversations = allConversations
        for index in candidateConversations.indices where candidateConversations[index].profileID == profileID && candidateConversations[index].projectID == projectID {
            let references = (candidateConversations[index].referenceDocumentIDs ?? []).filter { !ids.contains($0) }
            candidateConversations[index].referenceDocumentIDs = references.isEmpty ? nil : references
        }
        try commitProjectTransaction(profiles: candidateProfiles, conversations: candidateConversations)
    }

    /// Read-only inspection includes archive and trash, without selecting or restoring a conversation.
    func projectDocumentConversations(projectID: UUID, profileID: UUID) -> [Conversation] {
        guard !needsRecovery, activeProfileID == profileID,
              projects.contains(where: { $0.id == projectID }) else { return [] }
        return allConversations.filter { $0.profileID == profileID && $0.projectID == projectID }
    }

    func reviewProjectDocumentDeletion(_ documents: [ProjectDocument], projectID: UUID,
                                       profileID: UUID) throws -> ProjectDocumentDeletionReview {
        try requireProjectAccess(profileID: profileID)
        guard let project = projects.first(where: { $0.id == projectID }) else { throw ProjectError.missing }
        try ProjectDocumentBatch.validate(documents, in: project)
        let references = ProjectDocumentUsage.references(documentIDs: Set(documents.map(\.id)), projectID: projectID,
            profileID: profileID, conversations: allConversations)
        return ProjectDocumentDeletionReview(profileID: profileID, projectID: projectID,
            projectName: project.name, documents: documents, references: references)
    }

    func deleteReviewedProjectDocuments(_ review: ProjectDocumentDeletionReview) throws {
        let current = try reviewProjectDocumentDeletion(review.documents, projectID: review.projectID, profileID: review.profileID)
        guard current.references == review.references else { throw ProjectDocumentUsageError.changedReferences }
        try deleteProjectDocuments(review.documents, projectID: review.projectID, profileID: review.profileID)
    }

    func previewProjectReferenceReplacement(sourceID: UUID, targetID: UUID, conversationIDs: Set<UUID>,
                                             projectID: UUID, profileID: UUID) throws -> ProjectReferenceReplacementReview {
        try requireProjectAccess(profileID: profileID)
        guard sourceID != targetID else { throw ProjectReferenceReplacementError.sameDocument }
        guard !conversationIDs.isEmpty else { throw ProjectReferenceReplacementError.emptySelection }
        guard let project = projects.first(where: { $0.id == projectID }),
              let source = project.documents.first(where: { $0.id == sourceID }),
              let target = project.documents.first(where: { $0.id == targetID }) else { throw ProjectDocumentError.missing }
        let records = allConversations.filter { conversationIDs.contains($0.id) }
        guard records.count == conversationIDs.count else { throw ProjectReferenceReplacementError.changed }
        var rows: [ProjectReferenceReplacement.Row] = []
        for record in records {
            rows.append(try ProjectReferenceReplacement.makeRow(record, sourceID: sourceID, targetID: targetID, project: project, profileID: profileID))
        }
        rows.sort { first, second in
            if first.status.order != second.status.order { return first.status.order < second.status.order }
            return first.conversationID.uuidString < second.conversationID.uuidString
        }
        var involvedIDs: Set<UUID> = [sourceID, targetID]
        for row in rows { involvedIDs.formUnion(row.beforeIDs); involvedIDs.formUnion(row.afterIDs) }
        let documents = project.documents.filter { involvedIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return ProjectReferenceReplacementReview(profileID: profileID, projectID: projectID, projectName: project.name,
            source: source, target: target, documents: documents, rows: rows)
    }

    func applyProjectReferenceReplacement(_ review: ProjectReferenceReplacementReview) throws {
        let current = try previewProjectReferenceReplacement(sourceID: review.source.id, targetID: review.target.id,
            conversationIDs: Set(review.rows.map(\.conversationID)), projectID: review.projectID, profileID: review.profileID)
        guard current.projectName == review.projectName, current.source == review.source, current.target == review.target,
              current.documents == review.documents, current.rows == review.rows else { throw ProjectReferenceReplacementError.changed }
        var candidate = allConversations
        for row in current.rows {
            guard let index = candidate.firstIndex(where: { $0.id == row.conversationID }) else { throw ProjectReferenceReplacementError.changed }
            candidate[index].referenceDocumentIDs = row.afterIDs
        }
        // All checks finish before the single atomic write. Messages and composer state stay current.
        try commitConversations(candidate)
    }

    func previewProjectReferenceAddition(documentIDs: [UUID], conversationIDs: Set<UUID>,
                                         projectID: UUID, profileID: UUID) throws -> ProjectReferenceAdditionReview {
        try requireProjectAccess(profileID: profileID)
        guard !documentIDs.isEmpty else { throw ProjectReferenceAdditionError.noDocuments }
        guard !conversationIDs.isEmpty else { throw ProjectReferenceAdditionError.noConversations }
        guard let project = projects.first(where: { $0.id == projectID }) else { throw ProjectError.missing }
        let adding = try ProjectDocument.selected(ids: documentIDs, from: project)
        let records = allConversations.filter { conversationIDs.contains($0.id) }
        guard records.count == conversationIDs.count,
              records.allSatisfy({ $0.profileID == profileID && $0.projectID == projectID }) else {
            throw ProjectReferenceAdditionError.changed
        }
        var rows: [ProjectReferenceAddition.Row] = []
        for record in records {
            do { rows.append(try ProjectReferenceAddition.makeRow(record, adding: documentIDs, project: project, profileID: profileID)) }
            catch { throw ProjectReferenceAdditionError.incompatibleConversation(title: record.title, reason: error.localizedDescription) }
        }
        guard rows.contains(where: \.hasChanges) else { throw ProjectReferenceAdditionError.alreadyReferenced }
        rows.sort { first, second in
            if first.status.order != second.status.order { return first.status.order < second.status.order }
            return first.conversationID.uuidString < second.conversationID.uuidString
        }
        var involvedIDs = Set(documentIDs)
        for row in rows { involvedIDs.formUnion(row.beforeIDs); involvedIDs.formUnion(row.afterIDs) }
        let documents = project.documents.filter { involvedIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return ProjectReferenceAdditionReview(profileID: profileID, projectID: projectID, projectName: project.name,
            addingDocuments: adding, documents: documents, rows: rows)
    }

    func applyProjectReferenceAddition(_ review: ProjectReferenceAdditionReview) throws {
        let current = try previewProjectReferenceAddition(documentIDs: review.addingDocuments.map(\.id),
            conversationIDs: Set(review.rows.map(\.conversationID)), projectID: review.projectID, profileID: review.profileID)
        guard current.projectName == review.projectName, current.addingDocuments == review.addingDocuments,
              current.documents == review.documents, current.rows == review.rows else { throw ProjectReferenceAdditionError.changed }
        var candidate = allConversations
        for row in current.rows where row.hasChanges {
            guard let index = candidate.firstIndex(where: { $0.id == row.conversationID }) else { throw ProjectReferenceAdditionError.changed }
            candidate[index].referenceDocumentIDs = row.afterIDs
        }
        // Validate the entire reviewed batch before saving; keep current messages and drafts.
        try commitConversations(candidate)
    }

    func previewProjectReferenceRemoval(documentIDs: [UUID], conversationIDs: Set<UUID>,
                                         projectID: UUID, profileID: UUID) throws -> ProjectReferenceRemovalReview {
        try requireProjectAccess(profileID: profileID)
        guard !documentIDs.isEmpty else { throw ProjectReferenceRemovalError.noDocuments }
        guard !conversationIDs.isEmpty else { throw ProjectReferenceRemovalError.noConversations }
        guard let project = projects.first(where: { $0.id == projectID }) else { throw ProjectError.missing }
        let removing = try ProjectReferenceRemoval.selectedDocuments(documentIDs, in: project)
        let records = allConversations.filter { conversationIDs.contains($0.id) }
        guard records.count == conversationIDs.count,
              records.allSatisfy({ $0.profileID == profileID && $0.projectID == projectID }) else {
            throw ProjectReferenceRemovalError.changed
        }
        var rows: [ProjectReferenceRemoval.Row] = []
        for record in records {
            do { rows.append(try ProjectReferenceRemoval.makeRow(record, removing: documentIDs, project: project, profileID: profileID)) }
            catch { throw ProjectReferenceRemovalError.incompatibleConversation(title: record.title, reason: error.localizedDescription) }
        }
        guard rows.contains(where: \.hasChanges) else { throw ProjectReferenceRemovalError.notReferenced }
        rows.sort { first, second in
            if first.status.order != second.status.order { return first.status.order < second.status.order }
            return first.conversationID.uuidString < second.conversationID.uuidString
        }
        var involvedIDs = Set(documentIDs)
        for row in rows { involvedIDs.formUnion(row.beforeIDs); involvedIDs.formUnion(row.afterIDs) }
        let documents = project.documents.filter { involvedIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return ProjectReferenceRemovalReview(profileID: profileID, projectID: projectID, projectName: project.name,
            removingDocuments: removing, documents: documents, rows: rows)
    }

    func applyProjectReferenceRemoval(_ review: ProjectReferenceRemovalReview) throws {
        let current = try previewProjectReferenceRemoval(documentIDs: review.removingDocuments.map(\.id),
            conversationIDs: Set(review.rows.map(\.conversationID)), projectID: review.projectID, profileID: review.profileID)
        guard current.projectName == review.projectName, current.removingDocuments == review.removingDocuments,
              current.documents == review.documents, current.rows == review.rows else { throw ProjectReferenceRemovalError.changed }
        var candidate = allConversations
        for row in current.rows where row.hasChanges {
            guard let index = candidate.firstIndex(where: { $0.id == row.conversationID }) else { throw ProjectReferenceRemovalError.changed }
            candidate[index].referenceDocumentIDs = row.afterIDs
        }
        // Validate the entire reviewed batch before saving; keep current messages and drafts.
        try commitConversations(candidate)
    }

    func selectProjectDocuments(_ ids: [UUID], conversationID: UUID, profileID: UUID,
                                expectedSelection: [UUID]? = nil, expectedProjectID: UUID? = nil) throws {
        try requireProjectAccess(profileID: profileID)
        try requireWorkspaceAccess([conversationID])
        guard let index = allConversations.firstIndex(where: { $0.id == conversationID && $0.profileID == profileID }),
              let project = project(for: allConversations[index]) else { throw ProjectError.missing }
        if let expectedSelection, expectedSelection != (allConversations[index].referenceDocumentIDs ?? []) {
            throw ProjectDocumentError.changedSelection
        }
        if let expectedProjectID, expectedProjectID != project.id { throw ProjectDocumentError.changedSelection }
        _ = try ProjectDocument.selected(ids: ids, from: project)
        var candidate = allConversations
        candidate[index].referenceDocumentIDs = ids.isEmpty ? nil : ids
        try commitConversations(candidate)
    }

    func captureProjectDocument(_ target: LocalMessageTarget, profileID: UUID) throws -> ProjectDocumentCapture {
        try requireProjectAccess(profileID: profileID)
        try requireWorkspaceAccess([target.conversationID])
        guard let conversation = conversations.first(where: { $0.id == target.conversationID }),
              let message = conversation.messages.first(where: { $0.id == target.messageID }),
              project(for: conversation) != nil else { throw ProjectError.missing }
        return try ProjectDocumentCapture(message: message, conversation: conversation, profileID: profileID)
    }

    func prepareMessageProjectCapture(source: MessageLibraryBatchSnapshot, projectID: UUID) throws -> MessageProjectCapture {
        try requireProjectAccess(profileID: source.profileID)
        let current = try makeMessageLibraryBatch(source.items.map(\.id), profileID: source.profileID)
        guard current.profileName == source.profileName, current.items == source.items else { throw MessageProjectCaptureError.changed }
        guard source.items.contains(where: { !$0.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MessageProjectCaptureError.noText
        }
        guard let project = projects.first(where: { $0.id == projectID }) else { throw ProjectError.missing }
        return MessageProjectCapture(source: source, project: project)
    }

    func validateMessageProjectCapture(_ capture: MessageProjectCapture) throws {
        let current = try prepareMessageProjectCapture(source: capture.source, projectID: capture.project.id)
        guard current.project == capture.project else { throw MessageProjectCaptureError.changed }
    }

    @discardableResult
    func saveMessageProjectCapture(_ capture: MessageProjectCapture, title: String, body: String) throws -> UUID {
        try validateMessageProjectCapture(capture)
        return try saveProjectDocument(id: nil, projectID: capture.project.id, title: title,
            body: body, profileID: capture.source.profileID)
    }

    private func commitProjectProfiles(_ candidate: [ConnectionProfile]) throws {
        let library = ConnectionLibrary(profiles: candidate, activeID: activeProfileID, selectedConversations: selectedConversations)
        let data = try JSONEncoder().encode(library)
        try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        defaults.set(data, forKey: "connectionLibrary")
        profiles = candidate
    }

    private func commitProjectTransaction(profiles candidateProfiles: [ConnectionProfile], conversations candidateConversations: [Conversation]) throws {
        let library = ConnectionLibrary(profiles: candidateProfiles, activeID: activeProfileID, selectedConversations: selectedConversations)
        let state = BackupRestoreState(library: library, conversations: candidateConversations, drafts: try draftStore.snapshot(), images: [:])
        do {
            try BackupRestoreTransaction.commit(state, directory: directory, defaults: defaults)
            try draftStore.reload()
        } catch {
            // A partial transaction is recovered from the journal on next launch.
            storageLoadFailed = true
            throw error
        }
        profiles = candidateProfiles
        allConversations = candidateConversations
        refreshConversations()
    }

    func deleteProject(_ id: UUID, profileID: UUID) throws {
        try requireProjectAccess(profileID: profileID)
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[profileIndex].projects.contains(where: { $0.id == id }) else { throw ProjectError.missing }
        var candidateProfiles = profiles
        var projects = candidateProfiles[profileIndex].projects
        projects.removeAll { $0.id == id }
        candidateProfiles[profileIndex].projects = projects
        var candidateConversations = allConversations
        for index in candidateConversations.indices where candidateConversations[index].profileID == profileID && candidateConversations[index].projectID == id {
            candidateConversations[index].projectID = nil
            candidateConversations[index].referenceDocumentIDs = nil
        }
        try commitProjectTransaction(profiles: candidateProfiles, conversations: candidateConversations)
    }

    func assignConversations(_ ids: Set<UUID>, toProject projectID: UUID?, profileID: UUID) throws {
        try requireProjectAccess(profileID: profileID)
        try requireWorkspaceAccess(ids)
        if let projectID, !projects.contains(where: { $0.id == projectID }) { throw ProjectError.missing }
        var candidate = allConversations
        for index in candidate.indices where ids.contains(candidate[index].id) {
            if candidate[index].projectID != projectID { candidate[index].referenceDocumentIDs = nil }
            candidate[index].projectID = projectID
        }
        try commitConversations(candidate)
    }

    @discardableResult
    func startProjectConversation(_ id: UUID, profileID: UUID) throws -> UUID {
        try requireProjectAccess(profileID: profileID)
        guard projects.contains(where: { $0.id == id }) else { throw ProjectError.missing }
        try draftStore.set(draft, for: draftKey)
        let workspace = ConversationWorkspace(configuration: profiles.first { $0.id == profileID }?.conversationDefaults ?? ConversationConfiguration())
        let conversation = Conversation(title: "新对话", messages: [], updatedAt: Date(), profileID: profileID,
            workspace: workspace.isDefault ? nil : workspace, projectID: id)
        // Persist the empty conversation and its selection together before changing the composer.
        try commitWorkspaceTransaction([conversation] + allConversations, texts: draftStore.snapshot(), selectedID: conversation.id)
        return conversation.id
    }

    func checkConnection() async {
        let current = settings
        guard current.isConfigured else {
            connectionState = .unconfigured
            return
        }
        connectionState = .checking
        do {
            _ = try await HermesClient(settings: current, sessionConfiguration: sessionConfiguration).availableModels()
            if settings == current { connectionState = .connected }
        } catch {
            if settings == current { connectionState = .offline }
        }
    }

    func recordConnectionTest(success: Bool, settings tested: ConnectionSettings) {
        guard settings == tested else { return }
        connectionState = success ? .connected : .offline
    }

    @discardableResult
    func newConversation() -> Bool {
        guard !isSending else { return false }
        guard selectedID != nil else { return true }
        guard preserveCurrentDraft() else { return false }
        selectedID = nil
        rememberSelection()
        return true
    }

    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard !isSending, conversations.contains(where: { $0.id == id }) else { return false }
        guard id != selectedID else { return true }
        guard preserveCurrentDraft() else { return false }
        selectedID = id
        rememberSelection()
        return true
    }

    private func preserveCurrentDraft() -> Bool {
        guard !needsRecovery else { errorMessage = ProfileError.storageUnavailable.localizedDescription; return false }
        do { try draftStore.set(draft, for: draftKey); return true }
        catch { errorMessage = "草稿保存失败，已保留当前输入，暂未切换：\(error.localizedDescription)"; return false }
    }

    func delete(_ id: UUID) {
        do { try deleteConversations([id]) }
        catch { errorMessage = error.localizedDescription }
    }

    private func requireWorkspaceAccess(_ ids: Set<UUID>, inTrash: Bool = false) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard !isSending else { throw WorkspaceError.busy }
        let records = inTrash ? trashedConversations : conversations
        guard !ids.isEmpty, ids.isSubset(of: Set(records.map(\.id))) else { throw WorkspaceError.missing }
    }

    private func commitConversations(_ candidate: [Conversation]) throws {
        try JSONEncoder().encode(candidate).write(to: conversationsURL, options: .atomic)
        allConversations = candidate
        refreshConversations()
    }

    func setArchived(_ ids: Set<UUID>, archived: Bool) throws {
        try requireWorkspaceAccess(ids)
        var candidate = allConversations
        for index in candidate.indices where ids.contains(candidate[index].id) {
            var workspace = candidate[index].workspaceState
            workspace.archived = archived
            candidate[index].workspace = workspace.isDefault ? nil : workspace
        }
        try commitConversations(candidate)
    }

    func deleteConversations(_ ids: Set<UUID>) throws {
        try requireWorkspaceAccess(ids)
        var candidate = allConversations
        let now = Date()
        for index in candidate.indices where ids.contains(candidate[index].id) {
            var workspace = candidate[index].workspaceState
            workspace.trashedAt = now
            candidate[index].workspace = workspace
        }
        let nextID = selectedID.map { ids.contains($0) } == true ? nil : selectedID
        try commitWorkspaceTransaction(candidate, texts: draftStore.snapshot(), selectedID: nextID)
    }

    func restoreConversations(_ ids: Set<UUID>) throws {
        try requireWorkspaceAccess(ids, inTrash: true)
        var candidate = allConversations
        for index in candidate.indices where ids.contains(candidate[index].id) {
            var workspace = candidate[index].workspaceState
            workspace.trashedAt = nil
            candidate[index].workspace = workspace.isDefault ? nil : workspace
        }
        try commitConversations(candidate)
    }

    func permanentlyDeleteConversations(_ ids: Set<UUID>) throws {
        try requireWorkspaceAccess(ids, inTrash: true)
        let removedImages = Set(trashedConversations.filter { ids.contains($0.id) }.flatMap { $0.messages.compactMap(\.imageID) })
        let candidate = allConversations.filter { !ids.contains($0.id) }
        var texts = try draftStore.snapshot()
        for id in ids { texts.removeValue(forKey: DraftStore.localKey(profileID: activeProfileID, conversationID: id)) }
        try commitWorkspaceTransaction(candidate, texts: texts, selectedID: selectedID)
        removeUnusedImages(removedImages)
    }

    private func commitWorkspaceTransaction(_ candidate: [Conversation], texts: [String: String], selectedID nextID: UUID?) throws {
        var selections = selectedConversations
        selections[activeProfileID.uuidString] = nextID?.uuidString ?? ""
        let library = ConnectionLibrary(profiles: profiles, activeID: activeProfileID, selectedConversations: selections)
        do {
            try BackupRestoreTransaction.commit(BackupRestoreState(library: library, conversations: candidate, drafts: texts, images: [:]), directory: directory, defaults: defaults)
            try draftStore.reload()
        } catch {
            storageLoadFailed = true
            throw error
        }
        allConversations = candidate
        selectedConversations = selections
        selectedID = nextID
        refreshConversations()
        draft = draftStore.text(for: draftKey)
    }

    func saveConversationSettings(title: String, tags: String, configuration: ConversationConfiguration,
                                  expectedDraftKey: String, profileID: UUID, project: ProjectFilter? = nil) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard !isSending else { throw WorkspaceError.busy }
        guard expectedDraftKey == draftKey, profileID == activeProfileID else { throw WorkspaceError.changedContext }
        if project != nil && selectedID == nil { throw WorkspaceError.changedContext }
        if case .project(let id) = project, !projects.contains(where: { $0.id == id }) { throw ProjectError.missing }
        let configuration = try configuration.validated()
        if let id = selectedID {
            guard let index = allConversations.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { throw WorkspaceError.missing }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 80 else { throw ProfileError.missingName }
            var candidate = allConversations
            var workspace = candidate[index].workspaceState
            workspace.tags = try ConversationWorkspace.normalizedTags(tags)
            workspace.configuration = configuration
            candidate[index].title = title
            candidate[index].workspace = workspace.isDefault ? nil : workspace
            // nil and .all preserve membership; .unassigned explicitly removes it.
            let previousProjectID = candidate[index].projectID
            switch project {
            case .project(let id): candidate[index].projectID = id
            case .unassigned: candidate[index].projectID = nil
            case .all, nil: break
            }
            if candidate[index].projectID != previousProjectID { candidate[index].referenceDocumentIDs = nil }
            try commitConversations(candidate)
        } else {
            guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { throw WorkspaceError.changedContext }
            var candidate = profiles
            candidate[index].conversationDefaults = configuration.isDefault ? nil : configuration
            let library = ConnectionLibrary(profiles: candidate, activeID: activeProfileID, selectedConversations: selectedConversations)
            let data = try JSONEncoder().encode(library)
            try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
            defaults.set(data, forKey: "connectionLibrary")
            profiles = candidate
        }
    }

    func rename(_ id: UUID, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storageLoadFailed, !title.isEmpty, let index = allConversations.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID && !$0.isTrashed }) else { return }
        var candidate = allConversations
        candidate[index].title = String(title.prefix(80))
        do { try commitConversations(candidate) } catch { errorMessage = error.localizedDescription }
    }

    func togglePin(_ id: UUID) {
        guard !storageLoadFailed, !isSending,
              let index = allConversations.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID && !$0.isTrashed }) else { return }
        var candidate = allConversations
        candidate[index].pinned = !candidate[index].isPinned
        do { try commitConversations(candidate) } catch { errorMessage = error.localizedDescription }
    }

    func libraryItem(_ target: LocalMessageTarget) -> MessageLibraryItem? {
        guard let conversation = conversations.first(where: { $0.id == target.conversationID }),
              let message = conversation.messages.first(where: { $0.id == target.messageID }) else { return nil }
        return MessageLibraryItem(id: target, conversationTitle: conversation.title, message: message,
                                  conversationTags: conversation.workspaceState.tags, conversationArchived: conversation.isArchived,
                                  projectName: project(for: conversation)?.name, projectID: conversation.projectID)
    }

    func makeMessageLibraryBatch(_ targets: [LocalMessageTarget], profileID: UUID) throws -> MessageLibraryBatchSnapshot {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard activeProfileID == profileID, profiles.contains(where: { $0.id == profileID }) else { throw MessageLibraryBatchError.changed }
        guard !targets.isEmpty else { throw MessageLibraryBatchError.empty }
        guard targets.count <= MessageLibraryBatch.selectionLimit else { throw MessageLibraryBatchError.selectionLimit }
        guard Set(targets).count == targets.count else { throw MessageLibraryBatchError.duplicates }
        var items: [MessageLibraryItem] = []
        for target in targets {
            guard let item = libraryItem(target) else { throw MessageLibraryBatchError.changed }
            items.append(item)
        }
        try MessageLibraryBatch.validate(items)
        return MessageLibraryBatchSnapshot(profileID: profileID, profileName: activeProfileName,
            items: MessageLibraryBatch.ordered(items))
    }

    @discardableResult
    func changeMessageLibraryBookmarks(_ snapshot: MessageLibraryBatchSnapshot,
                                       operation: MessageLibraryBatchOperation) throws -> MessageLibraryBatchReport {
        let current = try makeMessageLibraryBatch(snapshot.items.map(\.id), profileID: snapshot.profileID)
        guard current.profileName == snapshot.profileName, current.items == snapshot.items else { throw MessageLibraryBatchError.changed }
        let report = MessageLibraryBatch.report(current.items, operation: operation)
        guard report.changed > 0 else { return report }
        var candidate = allConversations
        let now = Date()
        for item in current.items {
            guard let index = candidate.firstIndex(where: { $0.id == item.id.conversationID && $0.profileID == snapshot.profileID && !$0.isTrashed }),
                  let messageIndex = candidate[index].messages.firstIndex(where: { $0.id == item.id.messageID }) else { throw MessageLibraryBatchError.changed }
            if operation == .add {
                if candidate[index].messages[messageIndex].bookmark == nil {
                    candidate[index].messages[messageIndex].bookmark = MessageBookmark(createdAt: now, note: "")
                }
            } else { candidate[index].messages[messageIndex].bookmark = nil }
        }
        // One atomic save keeps unrelated incoming messages and every composer state intact.
        try commitConversations(candidate)
        return report
    }

    func toggleBookmark(_ target: LocalMessageTarget) throws {
        try changeBookmark(target) { current in
            current == nil ? MessageBookmark(createdAt: Date(), note: "") : nil
        }
    }

    func updateBookmarkNote(_ target: LocalMessageTarget, note: String) throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= MessageBookmark.noteLimit else { throw MessageLibraryError.noteTooLong }
        try changeBookmark(target) { current in
            guard var current else { throw MessageLibraryError.notBookmarked }
            current.note = note
            return current
        }
    }

    private func changeBookmark(_ target: LocalMessageTarget, transform: (MessageBookmark?) throws -> MessageBookmark?) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard let index = allConversations.firstIndex(where: { $0.id == target.conversationID && $0.profileID == activeProfileID && !$0.isTrashed }),
              let messageIndex = allConversations[index].messages.firstIndex(where: { $0.id == target.messageID }) else {
            throw MessageLibraryError.missing
        }
        var candidate = allConversations
        candidate[index].messages[messageIndex].bookmark = try transform(candidate[index].messages[messageIndex].bookmark)
        // Persist before publishing: a failed write must not show a successful star or note.
        try JSONEncoder().encode(candidate).write(to: conversationsURL, options: .atomic)
        allConversations = candidate
        refreshConversations()
    }

    func openMessage(_ target: LocalMessageTarget) throws {
        guard !isSending else { throw MessageLibraryError.busy }
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard libraryItem(target) != nil else { throw MessageLibraryError.missing }
        guard select(target.conversationID) else { throw WorkspaceError.draftSaveFailed }
    }

    func quoteMessage(_ target: LocalMessageTarget) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard let item = libraryItem(target) else { throw MessageLibraryError.missing }
        let next = (draft.isEmpty ? "" : draft + "\n\n") + MessageLibrary.quote(item) + "\n\n"
        guard next.count <= 100_000 else { throw MessageLibraryError.draftTooLong }
        try draftStore.set(next, for: draftKey)
        draftAlreadyPersisted = true
        defer { draftAlreadyPersisted = false }
        draft = next
    }

    private func messageDraftQuoteDestination() throws -> MessageDraftQuoteDestination {
        if let id = selectedID {
            guard let conversation = selectedConversation, conversation.id == id else { throw MessageDraftQuoteError.changed }
            guard !conversation.isArchived else { throw MessageDraftQuoteError.archivedDestination }
            return MessageDraftQuoteDestination(conversationID: id, title: conversation.title,
                projectID: conversation.projectID, projectName: project(for: conversation)?.name)
        }
        return MessageDraftQuoteDestination(conversationID: nil, title: "新对话", projectID: nil, projectName: nil)
    }

    func makeMessageDraftQuote(_ targets: [LocalMessageTarget], profileID: UUID) throws -> MessageDraftQuoteSnapshot {
        let source = try makeMessageLibraryBatch(targets, profileID: profileID)
        return MessageDraftQuoteSnapshot(source: source, draftKey: draftKey,
            destination: try messageDraftQuoteDestination(), draftText: draft)
    }

    func validateMessageDraftQuote(_ snapshot: MessageDraftQuoteSnapshot) throws {
        let current = try makeMessageLibraryBatch(snapshot.source.items.map(\.id), profileID: snapshot.source.profileID)
        guard current.profileName == snapshot.source.profileName, current.items == snapshot.source.items,
              snapshot.draftKey == draftKey, snapshot.draftText == draft,
              snapshot.destination == (try messageDraftQuoteDestination()) else { throw MessageDraftQuoteError.changed }
    }

    func applyMessageDraftQuote(_ snapshot: MessageDraftQuoteSnapshot, mode: PromptDraftMode) throws {
        try validateMessageDraftQuote(snapshot)
        let reference = try MessageDraftQuote.referenceText(snapshot.source)
        let next = try MessageDraftQuote.draft(current: snapshot.draftText, reference: reference, mode: mode)
        try draftStore.set(next, for: snapshot.draftKey)
        draftAlreadyPersisted = true
        defer { draftAlreadyPersisted = false }
        draft = next
    }

    var promptTemplates: [PromptTemplate] { profiles.first { $0.id == activeProfileID }?.templates ?? [] }

    @discardableResult
    func savePromptTemplate(id: UUID?, title: String, body: String, profileID: UUID) throws -> UUID {
        let templateID = id ?? UUID()
        try changePromptTemplates(profileID: profileID) { templates in
            let existing = id.flatMap { id in templates.first { $0.id == id } }
            if id != nil && existing == nil { throw PromptError.missing }
            let template = PromptTemplate(id: templateID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date(), pinned: existing?.pinned ?? false)
            try template.validate()
            if let index = templates.firstIndex(where: { $0.id == templateID }) { templates[index] = template }
            else { templates.append(template) }
        }
        return templateID
    }

    func togglePromptPin(_ id: UUID, profileID: UUID) throws {
        try changePromptTemplates(profileID: profileID) { templates in
            guard let index = templates.firstIndex(where: { $0.id == id }) else { throw PromptError.missing }
            templates[index].pinned.toggle()
        }
    }

    func deletePromptTemplate(_ id: UUID, profileID: UUID) throws {
        try changePromptTemplates(profileID: profileID) { templates in
            guard templates.contains(where: { $0.id == id }) else { throw PromptError.missing }
            templates.removeAll { $0.id == id }
        }
    }

    private func changePromptTemplates(profileID: UUID, change: (inout [PromptTemplate]) throws -> Void) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard profileID == activeProfileID, let index = profiles.firstIndex(where: { $0.id == profileID }) else { throw PromptError.changedContext }
        var candidate = profiles
        var templates = candidate[index].templates
        try change(&templates)
        try PromptTemplate.validateCollection(templates)
        candidate[index].templates = templates
        let library = ConnectionLibrary(profiles: candidate, activeID: activeProfileID, selectedConversations: selectedConversations)
        let data = try JSONEncoder().encode(library)
        try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
        defaults.set(data, forKey: "connectionLibrary")
        profiles = candidate
    }

    func applyPrompt(_ rendered: String, mode: PromptDraftMode, expectedDraftKey: String) throws {
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard expectedDraftKey == draftKey else { throw PromptError.changedContext }
        let next = try PromptRendering.draft(current: draft, rendered: rendered, mode: mode)
        try draftStore.set(next, for: draftKey)
        draftAlreadyPersisted = true
        defer { draftAlreadyPersisted = false }
        draft = next
    }

    func makeBackup() throws -> BackupArchive {
        guard !isSending else { throw ProfileError.sending }
        guard !storageLoadFailed else { throw ProfileError.storageUnavailable }
        var images: [String: Data] = [:]
        var imageBytes = 0
        for id in Set(allConversations.flatMap { $0.messages.compactMap(\.imageID) }) {
            let data: Data
            do { data = try ImageAttachmentStore.load(id, directory: attachmentDirectory) }
            catch { throw BackupError.missingImage }
            imageBytes += data.count
            guard imageBytes <= BackupArchive.byteLimit / 4 * 3 else { throw BackupError.tooLarge }
            images[id.uuidString] = data
        }
        var archive = BackupArchive(installationID: installationID, createdAt: Date(), profiles: profiles,
                                    conversations: allConversations, drafts: try draftStore.snapshot(), images: images)
        archive.version = archive.minimumVersion
        try archive.validate()
        return archive
    }

    func previewImport(_ archive: BackupArchive) throws -> BackupImportReport {
        try prepareImport(archive).report
    }

    @discardableResult
    func importBackup(_ archive: BackupArchive) throws -> BackupImportReport {
        let recovering = needsRecovery
        let merge = try prepareImport(archive)
        do {
            if recovering { try BackupRestoreTransaction.preserveOriginals(directory: directory, defaults: defaults) }
            try BackupRestoreTransaction.commit(merge.state, directory: directory, defaults: defaults)
            try draftStore.reload()
        } catch {
            // The journal is preserved for retry on next launch. Block further writes until recovery.
            storageLoadFailed = true
            errorMessage = "恢复未完成，原记录已保留。请重新打开 App 重试。"
            throw error
        }
        storageLoadFailed = false
        profiles = merge.state.library.profiles
        allConversations = merge.state.conversations
        if recovering {
            activeProfileID = merge.state.library.activeID
            selectedConversations = merge.state.library.selectedConversations
            selectedID = nil
            settings = profiles[0].settings(apiKey: credentials.read(account: profiles[0].credentialAccount))
            connectionState = .unconfigured
        }
        errorMessage = nil
        refreshConversations()
        draft = draftStore.text(for: draftKey)
        return merge.report
    }

    private func prepareImport(_ archive: BackupArchive) throws -> BackupMerge {
        guard !isSending else { throw ProfileError.sending }
        if needsRecovery {
            let empty = ConnectionProfile(id: recoveryProfileID, name: "默认连接", serverURL: "", model: "hermes-agent")
            return try BackupMerge.prepare(archive, installationID: installationID,
                library: ConnectionLibrary(profiles: [empty], activeID: empty.id), conversations: [], drafts: [:])
        }
        return try BackupMerge.prepare(archive, installationID: installationID,
            library: ConnectionLibrary(profiles: profiles, activeID: activeProfileID, selectedConversations: selectedConversations),
            conversations: allConversations, drafts: draftStore.snapshot())
    }

    func cancelSend() {
        activeTask?.cancel()
    }

    func previewNextRequest(_ rawText: String, hasImage: Bool, expectedDraftKey: String) throws -> ChatContextPreview {
        guard expectedDraftKey == draftKey else { throw WorkspaceError.changedContext }
        guard !needsRecovery else { throw ProfileError.storageUnavailable }
        guard !isSending else { throw WorkspaceError.busy }
        guard selectedConversation?.isArchived != true else { throw WorkspaceError.archived }
        let text = try ChatInput.text(rawText, hasImage: hasImage)
        let source = selectedConversation?.messages ?? []
        let input = ChatMessage(role: .user, content: text, imageID: hasImage ? UUID() : nil)
        return ChatContextPreview(profileID: activeProfileID, draftKey: draftKey, profileName: activeProfileName,
            fallbackModel: settings.model, rawText: rawText, inputID: input.id, sourceIDs: source.map(\.id),
            plan: try PreparedChatContext(messages: source + [input], configuration: conversationConfiguration, project: currentProject,
                referenceDocumentIDs: selectedConversation?.referenceDocumentIDs ?? []))
    }

    func retryLastResponse() {
        guard !isSending,
              settings.isConfigured,
              let selectedID,
              let conversation = selectedConversation,
              conversation.messages.last?.role == .user else { return }
        requestResponse(for: selectedID)
    }

    @discardableResult
    func branchConversation(at messageID: UUID) -> Bool {
        guard !isSending, !needsRecovery,
              let source = selectedConversation,
              let index = source.messages.firstIndex(where: { $0.id == messageID }) else { return false }
        return saveBranch(of: source, messages: Array(source.messages[...index])) != nil
    }

    @discardableResult
    func editAndResend(_ messageID: UUID, content: String, keepImage: Bool) -> Bool {
        guard !isSending, !needsRecovery,
              let source = selectedConversation,
              let index = source.messages.firstIndex(where: { $0.id == messageID }),
              source.messages[index].role == .user else { return false }
        let imageID = keepImage ? source.messages[index].imageID : nil
        let text: String
        do { text = try ChatInput.text(content, hasImage: imageID != nil) }
        catch { errorMessage = error.localizedDescription; return false }
        guard settings.isConfigured else {
            errorMessage = "请先在连接管理中填写 Hermes 服务地址和 API 密钥。"
            return false
        }
        if let imageID {
            do { _ = try ImageAttachmentStore.load(imageID, directory: attachmentDirectory) }
            catch {
                errorMessage = "原消息图片无法读取，请取消保留图片后重试。"
                return false
            }
        }
        var messages = Array(source.messages[..<index])
        messages.append(ChatMessage(role: .user, content: text, imageID: imageID))
        do {
            _ = try PreparedChatContext(messages: messages, configuration: source.workspaceState.configuration,
                project: project(for: source), referenceDocumentIDs: source.referenceDocumentIDs ?? [])
        } catch { errorMessage = error.localizedDescription; return false }
        guard let id = saveBranch(of: source, messages: messages) else { return false }
        requestResponse(for: id)
        return true
    }

    private func saveBranch(of source: Conversation, messages: [ChatMessage]) -> UUID? {
        // Fresh identities keep edits and search targets independent. Images remain shared
        // until no conversation references them; deletion already checks all profiles.
        let copies = messages.map { ChatMessage(role: $0.role, content: $0.content,
                                                createdAt: $0.createdAt, imageID: $0.imageID) }
        var workspace = source.workspaceState
        workspace.archived = false
        workspace.trashedAt = nil
        let branch = Conversation(title: String(source.title.prefix(75)) + " · 分支",
                                  messages: copies, updatedAt: Date(), profileID: activeProfileID,
                                  workspace: workspace.isDefault ? nil : workspace, projectID: source.projectID, referenceDocumentIDs: source.referenceDocumentIDs)
        let candidate = [branch] + allConversations
        do {
            try draftStore.set(draft, for: draftKey)
            try JSONEncoder().encode(candidate).write(to: conversationsURL, options: .atomic)
        } catch {
            errorMessage = "分支保存失败，尚未发送消息：\(error.localizedDescription)"
            return nil
        }
        allConversations = candidate
        refreshConversations()
        selectedID = branch.id
        rememberSelection()
        return branch.id
    }

    @discardableResult
    func send(_ rawText: String, imageData: Data? = nil) -> Bool {
        guard !needsRecovery else {
            errorMessage = ProfileError.storageUnavailable.localizedDescription
            return false
        }
        guard !isSending else { return false }
        let text: String
        do { text = try ChatInput.text(rawText, hasImage: imageData != nil) }
        catch { errorMessage = error.localizedDescription; return false }
        guard selectedConversation?.isArchived != true else {
            errorMessage = WorkspaceError.archived.localizedDescription
            return false
        }
        guard settings.isConfigured else {
            errorMessage = "请先在连接管理中填写 Hermes 服务地址和 API 密钥。"
            return false
        }

        do {
            _ = try PreparedChatContext(messages: (selectedConversation?.messages ?? []) + [ChatMessage(role: .user, content: text)],
                configuration: conversationConfiguration, project: currentProject,
                referenceDocumentIDs: selectedConversation?.referenceDocumentIDs ?? [])
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        var imageID: UUID?
        if let imageData {
            do { imageID = try ImageAttachmentStore.save(imageData, directory: attachmentDirectory) }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        let sentDraftKey = draftKey
        var candidate = allConversations
        var targetID = selectedID
        if targetID == nil {
            let title = text.isEmpty ? "图片对话" : String(text.prefix(38))
            let workspace = ConversationWorkspace(configuration: conversationConfiguration)
            let conversation = Conversation(title: title, messages: [], updatedAt: Date(), profileID: activeProfileID,
                                            workspace: workspace.isDefault ? nil : workspace)
            candidate.insert(conversation, at: 0)
            targetID = conversation.id
        }
        guard let targetID, let index = candidate.firstIndex(where: { $0.id == targetID }) else {
            if let imageID { ImageAttachmentStore.remove(imageID, directory: attachmentDirectory) }
            return false
        }
        if candidate[index].messages.isEmpty && candidate[index].title == "新对话" {
            candidate[index].title = text.isEmpty ? "图片对话" : String(text.prefix(38))
        }
        candidate[index].messages.append(
            ChatMessage(role: .user, content: text, imageID: imageID)
        )
        candidate[index].updatedAt = Date()
        do { try commitConversations(candidate) }
        catch {
            if let imageID { ImageAttachmentStore.remove(imageID, directory: attachmentDirectory) }
            errorMessage = "消息保存失败，尚未发送：\(error.localizedDescription)"
            return false
        }
        selectedID = targetID
        do { try draftStore.set("", for: sentDraftKey) }
        catch { errorMessage = "草稿清理失败：\(error.localizedDescription)" }
        rememberSelection()
        draft = ""
        requestResponse(for: targetID)
        return true
    }

    private func requestResponse(for id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        guard !conversation.isArchived else { errorMessage = WorkspaceError.archived.localizedDescription; return }
        let history = conversation.messages
        let configuration = conversation.workspaceState.configuration
        let project = project(for: conversation)
        let connection = settings
        isSending = true
        streamedReply = ""
        toolStatus = nil

        activeTask = Task {
            defer {
                isSending = false
                activeTask = nil
                streamedReply = ""
                toolStatus = nil
            }
            do {
                let reply = try await HermesClient(settings: connection, sessionConfiguration: sessionConfiguration, attachmentDirectory: attachmentDirectory).stream(
                    messages: history, configuration: configuration, project: project, referenceDocumentIDs: conversation.referenceDocumentIDs ?? []
                ) { event in
                    await MainActor.run {
                        switch event {
                        case .delta(let text):
                            streamedReply += text
                            toolStatus = nil
                        case .tool(let progress):
                            if progress.status == "completed" {
                                toolStatus = nil
                            } else {
                                toolStatus = [progress.emoji, progress.label ?? progress.tool]
                                    .compactMap { $0 }
                                    .joined(separator: " ")
                            }
                        }
                    }
                }
                if !Task.isCancelled,
                   let index = allConversations.firstIndex(where: { $0.id == id }) {
                    connectionState = .connected
                    allConversations[index].messages.append(
                        ChatMessage(role: .assistant, content: reply, createdAt: Date())
                    )
                    allConversations[index].updatedAt = Date()
                    persist()
                }
            } catch {
                if !Task.isCancelled {
                    if error is URLError { connectionState = .offline }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func removeUnusedImages(_ candidates: Set<UUID>) {
        let retained = Set(allConversations.flatMap { $0.messages.compactMap(\.imageID) })
        for id in candidates.subtracting(retained) { ImageAttachmentStore.remove(id, directory: attachmentDirectory) }
    }

    private func refreshConversations() {
        trashedConversations = allConversations.filter { $0.profileID == activeProfileID && $0.isTrashed }
            .sorted { $0.workspaceState.trashedAt! > $1.workspaceState.trashedAt! }
        conversations = allConversations.filter { $0.profileID == activeProfileID && !$0.isTrashed }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private func persist() {
        guard !storageLoadFailed else { return }
        refreshConversations()
        do { try JSONEncoder().encode(allConversations).write(to: conversationsURL, options: .atomic) }
        catch { errorMessage = "对话保存失败：\(error.localizedDescription)" }
    }

    enum ProfileError: LocalizedError {
        case sending, missingName, missingKey, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "本机连接或对话数据无法读取，请先恢复备份。原数据已保留。"
            case .sending: "请等待回复完成或停止后，再修改连接。"
            case .missingName: "请填写连接名称。"
            case .missingKey: "请填写 API 密钥。"
            }
        }
    }

    enum MessageLibraryError: LocalizedError {
        case missing, busy, noteTooLong, notBookmarked, draftTooLong
        var errorDescription: String? {
            switch self {
            case .missing: "这条消息已删除或不属于当前连接。"
            case .busy: "请先停止回复或等待完成，再回到原文。"
            case .noteTooLong: "收藏备注最多 2,000 字符。"
            case .notBookmarked: "这条消息尚未收藏，请先收藏后再添加备注。"
            case .draftTooLong: "引用后草稿超过 100,000 字符，请先缩短草稿。"
            }
        }
    }
}
