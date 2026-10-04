import XCTest
@testable import Hermes

final class WorkspaceTests: XCTestCase {
    override func tearDown() {
        WorkspaceURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testSessionPaginationDeduplicatesBackfilledPinsAndSearchesLoadedRecords() async throws {
        var offsets: [String] = []
        WorkspaceURLProtocol.handler = { request in
            let offset = URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "offset" }!.value!
            offsets.append(offset)
            request.respond(offset == "0" ?
                #"{"data":[{"id":"recent","title":"Planning","last_active":200,"pinned":false},{"id":"pin","title":"常用","last_active":10,"pinned":true}],"has_more":true}"# :
                #"{"data":[{"id":"pin","title":"常用","pinned":true,"last_active":10},{"id":"older","title":"工程","source":"CLI","preview":"Release checklist","last_active":20}],"has_more":false}"#)
        }
        let model = makeModel()
        await model.reloadSessions()
        XCTAssertEqual(model.sessions.map(\.id), ["pin", "recent"])
        XCTAssertTrue(model.filteredSessions(query: "checklist", pinnedOnly: false).isEmpty)
        XCTAssertTrue(model.hasMoreSessions)
        await model.loadMoreSessions()
        XCTAssertEqual(offsets, ["0", "50"])
        XCTAssertEqual(model.sessions.map(\.id), ["pin", "recent", "older"])
        XCTAssertEqual(model.filteredSessions(query: " release ", pinnedOnly: false).map(\.id), ["older"])
        XCTAssertEqual(model.filteredSessions(query: "cli", pinnedOnly: false).map(\.id), ["older"])
        XCTAssertEqual(model.filteredSessions(query: "", pinnedOnly: true).map(\.id), ["pin"])
        XCTAssertFalse(model.hasMoreSessions)
    }

    @MainActor
    func testFailedPaginationRetriesSameOffsetWithoutLosingRecords() async {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"data":[{"id":"first"}],"has_more":true}"#) }
        await model.reloadSessions()
        var attempts = 0
        WorkspaceURLProtocol.handler = { request in
            XCTAssertTrue(request.request.url!.query!.contains("offset=50"))
            attempts += 1
            if attempts == 1 { request.respond("unavailable", status: 503) }
            else { request.respond(#"{"data":[{"id":"next"}],"has_more":false}"#) }
        }
        await model.loadMoreSessions()
        XCTAssertNotNil(model.sessionsError)
        XCTAssertEqual(model.sessions.map(\.id), ["first"])
        XCTAssertTrue(model.hasMoreSessions)
        XCTAssertFalse(model.isLoadingMoreSessions)
        await model.loadMoreSessions()
        XCTAssertNil(model.sessionsError)
        XCTAssertEqual(Set(model.sessions.map(\.id)), ["first", "next"])
    }

    @MainActor
    func testRefreshFailurePreservesSessionsAndLastSuccessfulRefreshTime() async {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"data":[{"id":"saved"}],"has_more":false}"#) }
        await model.reloadSessions()
        let successfulTime = model.sessionsUpdatedAt
        WorkspaceURLProtocol.handler = { $0.respond("bad gateway", status: 502) }
        await model.reloadSessions()
        XCTAssertEqual(model.sessions.first?.id, "saved")
        XCTAssertEqual(model.sessionsUpdatedAt, successfulTime)
        XCTAssertNotNil(model.sessionsError)
        XCTAssertFalse(model.isLoadingSessions)
    }

    @MainActor
    func testInitialFailureIsDistinctFromEmptyAndSuccessfulRetryClearsError() async {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond("unauthorized", status: 401) }
        await model.reloadJobs()
        XCTAssertNotNil(model.jobsError)
        XCTAssertNil(model.jobsUpdatedAt)
        WorkspaceURLProtocol.handler = { $0.respond(#"{"jobs":[]}"#) }
        await model.reloadJobs()
        XCTAssertNil(model.jobsError)
        XCTAssertNotNil(model.jobsUpdatedAt)
    }

    @MainActor
    func testOlderSessionRefreshCannotOverwriteNewerResult() async {
        let model = makeModel()
        let started = expectation(description: "first request started")
        var delayed: WorkspaceURLProtocol?
        WorkspaceURLProtocol.handler = { request in
            delayed = request
            started.fulfill()
        }
        let older = Task { await model.reloadSessions() }
        await fulfillment(of: [started], timeout: 3)
        WorkspaceURLProtocol.handler = { $0.respond(#"{"data":[{"id":"new"}],"has_more":false}"#) }
        await model.reloadSessions()
        delayed?.respond(#"{"data":[{"id":"old"}],"has_more":true}"#)
        await older.value
        XCTAssertEqual(model.sessions.map(\.id), ["new"])
        XCTAssertFalse(model.hasMoreSessions)
        XCTAssertFalse(model.isLoadingSessions)
    }

    @MainActor
    func testCancelledLoadDoesNotShowAnError() async {
        let model = makeModel()
        let started = expectation(description: "request started")
        WorkspaceURLProtocol.handler = { _ in started.fulfill() }
        let task = Task { await model.reloadJobs() }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await task.value
        XCTAssertNil(model.jobsError)
        XCTAssertFalse(model.isLoadingJobs)
        XCTAssertNil(model.jobsUpdatedAt)
    }

    @MainActor
    func testPinSendsBooleanAndPreservesSummaryWhenMetadataResponseOmitsIt() async throws {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"data":[{"id":"a","title":"常用","preview":"保留摘要","message_count":8,"last_active":100,"pinned":false}],"has_more":false}"#) }
        await model.reloadSessions()
        let session = try XCTUnwrap(model.sessions.first)
        WorkspaceURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.path, "/p/work/api/sessions/a")
            XCTAssertEqual(request.request.httpMethod, "PATCH")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual((body["pinned"] as? NSNumber)?.objCType.pointee, Int8(99)) // JSON boolean, not string
            XCTAssertEqual(body["pinned"] as? Bool, true)
            request.respond(#"{"session":{"id":"a","pinned":true}}"#)
        }
        await model.togglePin(session)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.sessions.first?.pinned, true)
        XCTAssertEqual(model.sessions.first?.preview, "保留摘要")
        XCTAssertEqual(model.sessions.first?.messageCount, 8)
        XCTAssertEqual(model.sessions.first?.lastActive, 100)
        XCTAssertNil(model.busySessionID)
    }

    @MainActor
    func testUnsupportedPinDoesNotOptimisticallyChangeTheRecord() async throws {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"data":[{"id":"a","pinned":false}],"has_more":false}"#) }
        await model.reloadSessions()
        WorkspaceURLProtocol.handler = { $0.respond("unsupported_session_field", status: 400) }
        await model.togglePin(try XCTUnwrap(model.sessions.first))
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.sessions.first?.pinned, false)
        XCTAssertNil(model.busySessionID)
    }

    @MainActor
    func testJobFiltersCombineQueryAndStatusIncludingRecentFailures() async {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"jobs":[{"id":"a","name":"Digest","prompt":"新闻摘要","state":"scheduled","last_status":"delivery_failed"},{"id":"b","name":"健康检查","state":"paused","enabled":false},{"id":"c","name":"Done","state":"completed","enabled":false},{"id":"d","name":"Busy","state":"running"}]}"#) }
        await model.reloadJobs()
        XCTAssertEqual(model.filteredJobs(query: "新闻", filter: .attention).map(\.id), ["a"])
        XCTAssertEqual(model.filteredJobs(query: " digest ", filter: .scheduled).map(\.id), ["a"])
        XCTAssertEqual(model.filteredJobs(query: "", filter: .paused).map(\.id), ["b"])
        XCTAssertEqual(model.filteredJobs(query: "", filter: .completed).map(\.id), ["c"])
        XCTAssertEqual(model.filteredJobs(query: "", filter: .running).map(\.id), ["d"])
        XCTAssertEqual(model.jobs[2].statusLabel, "已完成")
        XCTAssertEqual(model.jobs[0].lastStatusLabel, "结果投递失败")
    }

    @MainActor
    func testJobDetailRefreshUsesProfileRouteAndUpdatesSharedList() async throws {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"jobs":[{"id":"a","name":"旧名称"}]}"#) }
        await model.reloadJobs()
        WorkspaceURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.path, "/p/work/api/jobs/a")
            request.respond(#"{"job":{"id":"a","name":"新名称","prompt":"完整任务说明","state":"running"}}"#)
        }
        await model.refreshJob("a")
        XCTAssertEqual(model.jobs.first?.name, "新名称")
        XCTAssertEqual(model.jobs.first?.prompt, "完整任务说明")
        XCTAssertNil(model.jobDetailError)
        WorkspaceURLProtocol.handler = { $0.respond("offline", status: 503) }
        await model.refreshJob("a")
        XCTAssertNotNil(model.jobDetailError)
        XCTAssertEqual(model.jobs.first?.name, "新名称")
    }

    @MainActor
    func testAcceptedManualRunIsNotReportedAsFailedWhenRefreshFails() async throws {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"jobs":[{"id":"a","name":"摘要","state":"paused"}]}"#) }
        await model.reloadJobs()
        WorkspaceURLProtocol.handler = { request in
            if request.request.url!.path.hasSuffix("/run") {
                request.respond(#"{"job":{"id":"a","name":"摘要","state":"scheduled"}}"#)
            } else { request.respond("offline", status: 503) }
        }
        await model.runJob(try XCTUnwrap(model.jobs.first))
        XCTAssertNotNil(model.notice)
        XCTAssertNotNil(model.jobsError)
        XCTAssertNotNil(model.jobDetailError)
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.busyJobID)
        XCTAssertEqual(model.jobs.count, 1)
    }

    @MainActor
    func testFailedDeletePreservesJobAndSuccessfulDeleteRemovesIt() async throws {
        let model = makeModel()
        WorkspaceURLProtocol.handler = { $0.respond(#"{"jobs":[{"id":"a","name":"任务"}]}"#) }
        await model.reloadJobs()
        let job = try XCTUnwrap(model.jobs.first)
        WorkspaceURLProtocol.handler = { $0.respond("offline", status: 503) }
        let failed = await model.deleteJob(job)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.jobs.count, 1)
        WorkspaceURLProtocol.handler = { $0.respond(#"{"ok":true}"#) }
        let deleted = await model.deleteJob(job)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testTimestampsRespectOffsetsAndPreserveUnknownTimezoneText() throws {
        let utc = try XCTUnwrap(RemoteTimestamp.date(from: "2026-10-04T01:00:00Z"))
        XCTAssertEqual(RemoteTimestamp.date(from: "2026-10-04T09:00:00+08:00"), utc)
        XCTAssertEqual(RemoteTimestamp.date(from: "2026-10-04T01:00:00.123456+00:00")?.timeIntervalSince(utc) ?? 0, 0.123456, accuracy: 0.001)
        XCTAssertNil(RemoteTimestamp.date(from: "2026-10-04T09:00:00"))
        XCTAssertNil(RemoteTimestamp.date(from: "not a date"))
        XCTAssertEqual(RemoteTimestamp.display("2026-10-04T09:00:00"), "2026-10-04T09:00:00")
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let displayed = RemoteTimestamp.display("2026-10-04T01:00:00Z", timeZone: zone, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(displayed.contains("09:00"), displayed)
    }

    @MainActor
    private func makeModel() -> RemoteWorkspaceModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocol.self]
        return RemoteWorkspaceModel(client: HermesClient(settings: ConnectionSettings(
            serverURL: "https://hermes.test/p/work/v1", model: "hermes-agent", apiKey: "fixture-key"),
            sessionConfiguration: configuration))
    }
}

private final class WorkspaceURLProtocol: URLProtocol {
    static var handler: ((WorkspaceURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    var body: Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let length = stream.read(&buffer, maxLength: buffer.count)
            if length <= 0 { break }
            result.append(contentsOf: buffer.prefix(length))
        }
        return result
    }

    func respond(_ json: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
