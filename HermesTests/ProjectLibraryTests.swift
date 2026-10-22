import XCTest
@testable import Hermes

final class ProjectLibraryTests: XCTestCase {
    func testProjectFilterCombinesWithRoleTagsAndArchiveScope() {
        let project = LocalProject(name: "发布项目", summary: "本机说明不应被消息库查询当作正文", instructions: "私有项目指令")
        let user = ChatMessage(role: .user, content: "需要发布", bookmark: MessageBookmark(createdAt: Date(), note: "要检查"))
        let assistant = ChatMessage(role: .assistant, content: "发布清单")
        let record = Conversation(title: "归档发布", messages: [user, assistant], updatedAt: Date(),
                                  workspace: ConversationWorkspace(tags: ["iOS"], archived: true), projectID: project.id)
        let unrelated = Conversation(title: "其他", messages: [user], updatedAt: Date())
        let matches = MessageLibrary.items(in: [record, unrelated], query: "发布项目", filter: .bookmarks, role: .user,
                                          scope: .archived, tag: "iOS", project: .project(project.id), projects: [project])
        XCTAssertEqual(matches.map(\.message.id), [user.id])
        XCTAssertEqual(matches.first?.projectName, "发布项目")
        XCTAssertTrue(MessageLibrary.items(in: [record], scope: .active, project: .project(project.id), projects: [project]).isEmpty)
        XCTAssertTrue(MessageLibrary.items(in: [record], tag: "工作", project: .project(project.id), projects: [project]).isEmpty)
        XCTAssertTrue(MessageLibrary.items(in: [record], query: "私有项目指令", projects: [project]).isEmpty)
        XCTAssertTrue(MessageLibrary.items(in: [record], query: project.summary, projects: [project]).isEmpty)
    }

    func testUnassignedAndTrashAreDistinctFromProjectMembership() {
        let projectID = UUID()
        let message = ChatMessage(role: .assistant, content: "内容")
        let assigned = Conversation(title: "项目内", messages: [message], updatedAt: Date(), projectID: projectID)
        let plain = Conversation(title: "未分组", messages: [message], updatedAt: Date())
        let trashed = Conversation(title: "回收站", messages: [message], updatedAt: Date(),
                                   workspace: ConversationWorkspace(trashedAt: Date()), projectID: projectID)
        XCTAssertEqual(MessageLibrary.items(in: [assigned, plain, trashed], project: .unassigned).map(\.conversationTitle), ["未分组"])
        XCTAssertEqual(MessageLibrary.items(in: [assigned, plain, trashed], project: .project(projectID)).map(\.conversationTitle), ["项目内"])
        XCTAssertEqual(ConversationWorkbench.filtered([assigned, plain, trashed], scope: .trash, query: "", tag: nil,
                                                     sort: .recent, project: .project(projectID)).map(\.id), [trashed.id])
    }
}
