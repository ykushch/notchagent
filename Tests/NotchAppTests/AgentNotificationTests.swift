import Foundation
import HerdrClient
import Testing
@testable import NotchApp

@MainActor
private final class RecordingNotificationScheduler: AgentNotificationScheduling {
    var responseHandler: ((AgentNotificationResponse) -> Void)?
    var status: AgentNotificationAuthorization = .authorized
    var authorizationRequests = 0
    var registeredCategories = 0
    var added: [AgentNotificationRequest] = []
    var delivered: [String: ScheduledAgentNotification] = [:]
    var pending: [String: ScheduledAgentNotification] = [:]
    var removedDelivered: [String] = []
    var removedPending: [String] = []

    func registerAgentCategory() { registeredCategories += 1 }
    func authorizationStatus() async -> AgentNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        status = .authorized
        return true
    }
    func deliveredNotifications() async -> [ScheduledAgentNotification] {
        Array(delivered.values)
    }
    func pendingNotifications() async -> [ScheduledAgentNotification] {
        Array(pending.values)
    }
    func add(_ request: AgentNotificationRequest) async throws {
        added.append(request)
        delivered[request.identifier] = ScheduledAgentNotification(
            identifier: request.identifier,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            metadata: request.metadata)
    }
    func removeDelivered(identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
        for identifier in identifiers { delivered[identifier] = nil }
    }
    func removePending(identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
        for identifier in identifiers { pending[identifier] = nil }
    }
}

@Suite("Agent notifications")
@MainActor
struct AgentNotificationTests {
    @Test("notification identity is scoped by session as well as pane")
    func sessionScopedIdentity() {
        let local = item(sessionID: "local:default", paneID: "w1:p1", status: .blocked)
        let remote = item(
            sessionID: "ssh:workbox/default", paneID: "w1:p1", status: .blocked)

        let localRequest = AgentNotificationPayloadBuilder.request(
            item: local, kind: .blocked, respectDND: true)
        let remoteRequest = AgentNotificationPayloadBuilder.request(
            item: remote, kind: .blocked, respectDND: true)

        #expect(localRequest.identifier != remoteRequest.identifier)
        #expect(localRequest.threadIdentifier != remoteRequest.threadIdentifier)
        #expect(localRequest.metadata.ref == local.ref)
        #expect(remoteRequest.metadata.ref == remote.ref)
    }

    @Test("payload reuses attention language and maps Focus policy")
    func payloadContentAndInterruption() {
        let finished = item(
            sessionID: "local:default", paneID: "w1:p2", status: .done,
            completionSummary: "Implemented authentication and added tests.")

        let respectful = AgentNotificationPayloadBuilder.request(
            item: finished, kind: .done, respectDND: true)
        let urgent = AgentNotificationPayloadBuilder.request(
            item: finished, kind: .done, respectDND: false,
            supportsTimeSensitive: true)

        #expect(respectful.title == "Codex finished")
        #expect(respectful.subtitle == "project")
        #expect(respectful.body == "Implemented authentication and added tests.")
        #expect(respectful.interruption == .active)
        #expect(urgent.interruption == .timeSensitive)
    }

    @Test("ad-hoc builds never request the restricted interruption level")
    func adHocInterruptionFallback() {
        let request = AgentNotificationPayloadBuilder.request(
            item: item(status: .blocked),
            kind: .blocked,
            respectDND: false,
            supportsTimeSensitive: false)

        #expect(request.interruption == .active)
    }

    @Test("identical delivered content does not alert twice")
    func deliveredDeduplication() async {
        let (controller, scheduler, _) = makeController()
        let request = AgentNotificationPayloadBuilder.request(
            item: item(status: .blocked), kind: .blocked, respectDND: true)

        await controller.deliver(request)
        await controller.deliver(request)

        #expect(scheduler.added.count == 1)
        #expect(scheduler.delivered.count == 1)
    }

    @Test("new content replaces the stable per-agent request")
    func contentReplacement() async {
        let (controller, scheduler, _) = makeController()
        let first = AgentNotificationPayloadBuilder.request(
            item: item(status: .done, completionSummary: "First result"),
            kind: .done, respectDND: true)
        let second = AgentNotificationPayloadBuilder.request(
            item: item(status: .done, completionSummary: "Second result"),
            kind: .done, respectDND: true)

        await controller.deliver(first)
        await controller.deliver(second)

        #expect(scheduler.added.count == 2)
        #expect(first.identifier == second.identifier)
        #expect(scheduler.delivered[first.identifier]?.body == "Second result")
    }

    @Test("resolved panes remove blocked alerts but preserve completion history")
    func resolutionCleanup() async {
        let (controller, scheduler, _) = makeController()
        let blocked = AgentNotificationPayloadBuilder.request(
            item: item(status: .blocked), kind: .blocked, respectDND: true)
        let done = AgentNotificationPayloadBuilder.request(
            item: item(status: .done, completionSummary: "Finished"),
            kind: .done, respectDND: true)
        await controller.deliver(blocked)
        await controller.deliver(done)

        // Reinstall a blocked record to model a different still-delivered pane
        // state; posting done intentionally removes the blocked predecessor.
        scheduler.delivered[blocked.identifier] = ScheduledAgentNotification(
            identifier: blocked.identifier,
            title: blocked.title,
            subtitle: blocked.subtitle,
            body: blocked.body,
            metadata: blocked.metadata)
        await controller.reconcileBlockedNow(
            sessionID: blocked.metadata.ref.sessionID, activeRefs: [])

        #expect(scheduler.delivered[blocked.identifier] == nil)
        #expect(scheduler.delivered[done.identifier] != nil)
        #expect(scheduler.removedDelivered.contains(blocked.identifier))
        #expect(scheduler.removedPending.contains(blocked.identifier))
    }

    @Test("notification actions queue until a full AgentRef router is installed")
    func queuedActionRouting() {
        let (controller, scheduler, _) = makeController()
        let ref = AgentRef(sessionID: "ssh:workbox/default", paneID: "w1:p1")
        controller.start()

        scheduler.responseHandler?(AgentNotificationResponse(action: .jump, ref: ref))
        var routed: AgentRef?
        controller.setActionHandler { routed = $0 }

        #expect(routed == ref)
    }

    @Test("disabled notifications do not schedule content")
    func disabledPolicy() async {
        let (controller, scheduler, settings) = makeController()
        settings.notificationsEnabled = false
        let request = AgentNotificationPayloadBuilder.request(
            item: item(status: .blocked), kind: .blocked, respectDND: true)

        await controller.deliver(request)

        #expect(scheduler.added.isEmpty)
    }

    @Test("the shared transition sink posts the reconciled attention row")
    func transitionIntegration() async throws {
        let (controller, scheduler, settings) = makeController()
        let model = NotchViewModel()
        model.settings = settings
        model.notificationController = controller
        model.presentation = .overview
        model.registry.apply([ResolvedSession(local: SessionDescriptor(
            kind: .local(name: "default"),
            serverSocketPath: "/tmp/notchagent-notification-test.sock",
            isDefault: true,
            isRunning: true))])
        let runtime = try #require(model.registry.runtime(for: "local:default"))
        runtime.store.hydrate(Snapshot(panes: [PaneInfo(
            paneID: "w1:p1",
            terminalID: "term-1",
            workspaceID: "w1",
            tabID: "w1:t1",
            focused: false,
            agentStatus: .blocked,
            revision: 1,
            agent: "claude",
            displayAgent: "Claude",
            cwd: "/work/project")]))

        await model.sessionRuntime(runtime, didObserve: .init(
            newlyBlockedPaneIDs: ["w1:p1"]))
        for _ in 0..<10 where scheduler.added.isEmpty { await Task.yield() }

        let posted = try #require(scheduler.added.first)
        #expect(posted.metadata.ref == AgentRef(
            sessionID: "local:default", paneID: "w1:p1"))
        #expect(posted.title == "Claude needs input")
        #expect(posted.subtitle == "project")
    }

    @Test("an event observed during the permission prompt is delivered after authorization")
    func permissionDeferral() async {
        let (controller, scheduler, _) = makeController()
        scheduler.status = .notDetermined
        let request = AgentNotificationPayloadBuilder.request(
            item: item(status: .blocked), kind: .blocked, respectDND: true)

        await controller.deliver(request)

        #expect(scheduler.authorizationRequests == 1)
        #expect(scheduler.added == [request])
        #expect(controller.authorization == .authorized)
    }

    private func makeController() -> (
        AgentNotificationController, RecordingNotificationScheduler, Settings
    ) {
        let suiteName = "NotchAppTests.Notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = Settings(defaults: defaults)
        let scheduler = RecordingNotificationScheduler()
        return (
            AgentNotificationController(settings: settings, scheduler: scheduler),
            scheduler,
            settings)
    }

    private func item(
        sessionID: String = "local:default",
        paneID: String = "w1:p1",
        status: RollupStatus,
        completionSummary: String? = nil
    ) -> InteractionAttentionDisplayModel {
        InteractionAttentionDisplayModel(
            paneID: paneID,
            sessionID: sessionID,
            taskTitle: "Fix auth",
            agentName: "Codex",
            workspaceLabel: "project",
            status: status,
            state: nil,
            completionSummary: completionSummary,
            isSelected: false)
    }
}
