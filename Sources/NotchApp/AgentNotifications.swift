import Foundation
import HerdrClient
import Observation
@preconcurrency import UserNotifications

enum AgentNotificationKind: String, Sendable, Equatable {
    case blocked
    case done
}

enum AgentNotificationInterruption: Sendable, Equatable {
    case active
    case timeSensitive
}

enum AgentNotificationAuthorization: Sendable, Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized

    var summary: String {
        switch self {
        case .unknown: "Checking system permission…"
        case .notDetermined: "Permission not requested"
        case .denied: "Disabled in System Settings"
        case .authorized: "Allowed by macOS"
        }
    }
}

struct AgentNotificationMetadata: Sendable, Equatable {
    static let sessionIDKey = "notchagent.session-id"
    static let paneIDKey = "notchagent.pane-id"
    static let kindKey = "notchagent.event-kind"

    let ref: AgentRef
    let kind: AgentNotificationKind
}

struct AgentNotificationRequest: Sendable, Equatable {
    static let categoryIdentifier = "notchagent.agent-event"
    static let jumpActionIdentifier = "notchagent.jump"

    let identifier: String
    let threadIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let interruption: AgentNotificationInterruption
    let metadata: AgentNotificationMetadata
}

struct ScheduledAgentNotification: Sendable, Equatable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
    let metadata: AgentNotificationMetadata?

    func hasSameContent(as request: AgentNotificationRequest) -> Bool {
        title == request.title
            && subtitle == request.subtitle
            && body == request.body
            && metadata == request.metadata
    }
}

enum AgentNotificationResponseAction: Sendable, Equatable {
    case open
    case jump
    case dismiss
    case other
}

struct AgentNotificationResponse: Sendable, Equatable {
    let action: AgentNotificationResponseAction
    let ref: AgentRef?
}

enum AgentNotificationPayloadBuilder {
    static func request(
        item: InteractionAttentionDisplayModel,
        kind: AgentNotificationKind,
        respectDND: Bool,
        supportsTimeSensitive: Bool = false
    ) -> AgentNotificationRequest {
        let token = identityToken(for: item.ref)
        let sessionContext = item.sessionLabel.map { " · \($0)" } ?? ""
        return AgentNotificationRequest(
            identifier: "notchagent.agent.\(token).\(kind.rawValue)",
            threadIdentifier: "notchagent.agent.\(token)",
            title: kind == .blocked
                ? "\(item.agentName) needs input"
                : "\(item.agentName) finished",
            subtitle: "\(item.workspaceLabel)\(sessionContext)",
            body: clipped(item.summary),
            interruption: !respectDND && supportsTimeSensitive
                ? .timeSensitive : .active,
            metadata: AgentNotificationMetadata(ref: item.ref, kind: kind))
    }

    static func identifier(for ref: AgentRef, kind: AgentNotificationKind) -> String {
        "notchagent.agent.\(identityToken(for: ref)).\(kind.rawValue)"
    }

    private static func identityToken(for ref: AgentRef) -> String {
        let value = "\(ref.sessionID.utf8.count):\(ref.sessionID)\(ref.paneID)"
        return Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func clipped(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}

@MainActor
protocol AgentNotificationScheduling: AnyObject {
    var responseHandler: ((AgentNotificationResponse) -> Void)? { get set }

    func registerAgentCategory()
    func authorizationStatus() async -> AgentNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func deliveredNotifications() async -> [ScheduledAgentNotification]
    func pendingNotifications() async -> [ScheduledAgentNotification]
    func add(_ request: AgentNotificationRequest) async throws
    func removeDelivered(identifiers: [String])
    func removePending(identifiers: [String])
}

@MainActor
final class SystemAgentNotificationScheduler: NSObject, AgentNotificationScheduling {
    private let center: UNUserNotificationCenter
    var responseHandler: ((AgentNotificationResponse) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func registerAgentCategory() {
        let jump = UNNotificationAction(
            identifier: AgentNotificationRequest.jumpActionIdentifier,
            title: "Jump",
            options: [.foreground])
        let category = UNNotificationCategory(
            identifier: AgentNotificationRequest.categoryIdentifier,
            actions: [jump],
            intentIdentifiers: [],
            options: [])
        center.setNotificationCategories([category])
    }

    func authorizationStatus() async -> AgentNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func deliveredNotifications() async -> [ScheduledAgentNotification] {
        await center.deliveredNotifications().map(Self.record)
    }

    func pendingNotifications() async -> [ScheduledAgentNotification] {
        await center.pendingNotificationRequests().map(Self.record)
    }

    func add(_ request: AgentNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.subtitle = request.subtitle
        content.body = request.body
        content.categoryIdentifier = AgentNotificationRequest.categoryIdentifier
        content.threadIdentifier = request.threadIdentifier
        content.interruptionLevel = switch request.interruption {
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
        content.userInfo = [
            AgentNotificationMetadata.sessionIDKey: request.metadata.ref.sessionID,
            AgentNotificationMetadata.paneIDKey: request.metadata.ref.paneID,
            AgentNotificationMetadata.kindKey: request.metadata.kind.rawValue,
        ]
        try await center.add(UNNotificationRequest(
            identifier: request.identifier, content: content, trigger: nil))
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func record(_ notification: UNNotification) -> ScheduledAgentNotification {
        record(notification.request)
    }

    private static func record(_ request: UNNotificationRequest) -> ScheduledAgentNotification {
        ScheduledAgentNotification(
            identifier: request.identifier,
            title: request.content.title,
            subtitle: request.content.subtitle,
            body: request.content.body,
            metadata: metadata(from: request.content.userInfo))
    }

    nonisolated private static func metadata(
        from userInfo: [AnyHashable: Any]
    ) -> AgentNotificationMetadata? {
        guard let sessionID = userInfo[AgentNotificationMetadata.sessionIDKey] as? String,
              let paneID = userInfo[AgentNotificationMetadata.paneIDKey] as? String,
              let rawKind = userInfo[AgentNotificationMetadata.kindKey] as? String,
              let kind = AgentNotificationKind(rawValue: rawKind) else { return nil }
        return AgentNotificationMetadata(
            ref: AgentRef(sessionID: sessionID, paneID: paneID), kind: kind)
    }
}

extension SystemAgentNotificationScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action: AgentNotificationResponseAction = switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: .open
        case AgentNotificationRequest.jumpActionIdentifier: .jump
        case UNNotificationDismissActionIdentifier: .dismiss
        default: .other
        }
        let metadata = Self.metadata(from: response.notification.request.content.userInfo)
        let routed = AgentNotificationResponse(action: action, ref: metadata?.ref)
        await MainActor.run { [weak self] in self?.responseHandler?(routed) }
    }
}

@Observable
@MainActor
final class AgentNotificationController {
    private let settings: Settings
    @ObservationIgnored private let scheduler: any AgentNotificationScheduling
    @ObservationIgnored private var actionHandler: ((AgentRef) -> Void)?
    @ObservationIgnored private var queuedActions: [AgentRef] = []
    @ObservationIgnored private var deferredRequests: [String: AgentNotificationRequest] = [:]
    @ObservationIgnored private var authorizationRequestInFlight = false
    let supportsTimeSensitive: Bool
    private(set) var authorization: AgentNotificationAuthorization = .unknown

    init(
        settings: Settings,
        scheduler: any AgentNotificationScheduling = SystemAgentNotificationScheduler(),
        supportsTimeSensitive: Bool = Bundle.main.object(
            forInfoDictionaryKey: "NotchAgentTimeSensitiveNotifications") as? Bool ?? false
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.supportsTimeSensitive = supportsTimeSensitive
    }

    func start() {
        scheduler.registerAgentCategory()
        scheduler.responseHandler = { [weak self] response in
            self?.handle(response)
        }
        refreshAuthorization(requestIfNeeded: settings.notificationsEnabled)
    }

    func stop() {
        scheduler.responseHandler = nil
        actionHandler = nil
        queuedActions = []
        deferredRequests = [:]
    }

    func setActionHandler(_ handler: @escaping (AgentRef) -> Void) {
        actionHandler = handler
        let queued = queuedActions
        queuedActions = []
        for ref in queued { handler(ref) }
    }

    func settingsDidChange() {
        if !settings.notificationsEnabled { deferredRequests = [:] }
        refreshAuthorization(requestIfNeeded: settings.notificationsEnabled)
    }

    func refreshAuthorization(requestIfNeeded: Bool) {
        Task { @MainActor in await refreshAuthorizationNow(
            requestIfNeeded: requestIfNeeded) }
    }

    func post(item: InteractionAttentionDisplayModel, kind: AgentNotificationKind) {
        let request = AgentNotificationPayloadBuilder.request(
            item: item,
            kind: kind,
            respectDND: settings.respectDND,
            supportsTimeSensitive: supportsTimeSensitive)
        Task { @MainActor in await deliver(request) }
    }

    func reconcileBlocked(sessionID: String, activeRefs: Set<AgentRef>) {
        Task { @MainActor in
            await reconcileBlockedNow(sessionID: sessionID, activeRefs: activeRefs)
        }
    }

    func removeNotifications(for ref: AgentRef) {
        remove(identifiers: AgentNotificationKind.allCases.map {
            AgentNotificationPayloadBuilder.identifier(for: ref, kind: $0)
        })
    }

    func removeNotifications(sessionID: String) {
        Task { @MainActor in
            let records = await scheduler.deliveredNotifications()
                + scheduler.pendingNotifications()
            let identifiers = records.compactMap { record in
                record.metadata?.ref.sessionID == sessionID ? record.identifier : nil
            }
            remove(identifiers: identifiers)
        }
    }

    func deliver(_ request: AgentNotificationRequest) async {
        guard settings.notificationsEnabled else { return }
        let status = await scheduler.authorizationStatus()
        authorization = status
        guard status == .authorized else {
            if status == .notDetermined {
                deferredRequests[request.identifier] = request
                await refreshAuthorizationNow(requestIfNeeded: true)
            }
            return
        }

        await schedule(request)
    }

    private func refreshAuthorizationNow(requestIfNeeded: Bool) async {
        var status = await scheduler.authorizationStatus()
        if status == .notDetermined, requestIfNeeded, !authorizationRequestInFlight {
            authorizationRequestInFlight = true
            _ = try? await scheduler.requestAuthorization()
            authorizationRequestInFlight = false
            status = await scheduler.authorizationStatus()
        }
        authorization = status
        if status == .denied { deferredRequests = [:] }
        guard status == .authorized, settings.notificationsEnabled,
              !deferredRequests.isEmpty else { return }
        let requests = Array(deferredRequests.values)
        deferredRequests = [:]
        for request in requests { await schedule(request) }
    }

    private func schedule(_ request: AgentNotificationRequest) async {
        if request.metadata.kind == .done {
            remove(identifiers: [AgentNotificationPayloadBuilder.identifier(
                for: request.metadata.ref, kind: .blocked)])
        }
        let existing = await scheduler.deliveredNotifications()
            + scheduler.pendingNotifications()
        if existing.contains(where: {
            $0.identifier == request.identifier && $0.hasSameContent(as: request)
        }) { return }
        try? await scheduler.add(request)
    }

    func reconcileBlockedNow(sessionID: String, activeRefs: Set<AgentRef>) async {
        let records = await scheduler.deliveredNotifications()
            + scheduler.pendingNotifications()
        let identifiers = records.compactMap { record -> String? in
            guard let metadata = record.metadata,
                  metadata.kind == .blocked,
                  metadata.ref.sessionID == sessionID,
                  !activeRefs.contains(metadata.ref) else { return nil }
            return record.identifier
        }
        remove(identifiers: identifiers)
    }

    private func handle(_ response: AgentNotificationResponse) {
        guard response.action == .open || response.action == .jump,
              let ref = response.ref else { return }
        if let actionHandler {
            actionHandler(ref)
        } else if !queuedActions.contains(ref) {
            queuedActions.append(ref)
        }
    }

    private func remove(identifiers: [String]) {
        let unique = Array(Set(identifiers))
        guard !unique.isEmpty else { return }
        scheduler.removePending(identifiers: unique)
        scheduler.removeDelivered(identifiers: unique)
    }
}

private extension AgentNotificationKind {
    static var allCases: [AgentNotificationKind] { [.blocked, .done] }
}
