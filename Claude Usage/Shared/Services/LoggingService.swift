//
//  LoggingService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-20.
//

import Foundation
import os.log

/// Centralized logging service using os.log
/// Provides consistent logging across the application
final class LoggingService {
    static let shared = LoggingService()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.claudeusage"

    // Category-specific loggers
    private lazy var apiLogger = OSLog(subsystem: subsystem, category: "API")
    private lazy var storageLogger = OSLog(subsystem: subsystem, category: "Storage")
    private lazy var notificationLogger = OSLog(subsystem: subsystem, category: "Notifications")
    private lazy var uiLogger = OSLog(subsystem: subsystem, category: "UI")
    private lazy var generalLogger = OSLog(subsystem: subsystem, category: "General")

    private init() {}

    // MARK: - API Logging

    func logAPIRequest(_ endpoint: String) {
        os_log("📤 API Request: %{public}@", log: apiLogger, type: .info, endpoint)
    }

    func logAPIResponse(_ endpoint: String, statusCode: Int) {
        os_log("📥 API Response: %{public}@ [%d]", log: apiLogger, type: .info, endpoint, statusCode)
    }

    func logAPIError(_ endpoint: String, error: Error) {
        os_log("❌ API Error: %{public}@ - %{public}@", log: apiLogger, type: .error, endpoint, error.localizedDescription)
    }

    // MARK: - Storage Logging

    func logStorageSave(_ key: String) {
        os_log("💾 Storage Save: %{public}@", log: storageLogger, type: .debug, key)
    }

    func logStorageLoad(_ key: String, success: Bool) {
        if success {
            os_log("📂 Storage Load: %{public}@ ✓", log: storageLogger, type: .debug, key)
        } else {
            os_log("📂 Storage Load: %{public}@ ✗ (not found)", log: storageLogger, type: .debug, key)
        }
    }

    func logStorageError(_ operation: String, error: Error) {
        os_log("❌ Storage Error [%{public}@]: %{public}@", log: storageLogger, type: .error, operation, error.localizedDescription)
    }

    // MARK: - Notification Logging

    func logNotificationSent(_ type: String) {
        os_log("🔔 Notification Sent: %{public}@", log: notificationLogger, type: .info, type)
    }

    func logNotificationError(_ error: Error) {
        os_log("❌ Notification Error: %{public}@", log: notificationLogger, type: .error, error.localizedDescription)
    }

    func logNotificationPermission(_ granted: Bool) {
        os_log("🔐 Notification Permission: %{public}@", log: notificationLogger, type: .info, granted ? "Granted" : "Denied")
    }

    // MARK: - UI Logging

    func logUIEvent(_ event: String) {
        os_log("🖱️ UI Event: %{public}@", log: uiLogger, type: .debug, event)
    }

    func logWindowEvent(_ event: String) {
        os_log("🪟 Window Event: %{public}@", log: uiLogger, type: .debug, event)
    }

    // MARK: - General Logging

    /// Tests only: sees every general/error message as it is sent to the
    /// system log, so a test can prove a secret never reaches it.
    static var testSink: ((String) -> Void)?

    func log(_ message: String, type: OSLogType = .default) {
        Self.testSink?(message)
        os_log("%{public}@", log: generalLogger, type: type, message)
    }

    func logError(_ message: String, error: Error? = nil) {
        Self.testSink?(error.map { "\(message): \($0.localizedDescription)" } ?? message)
        if let error = error {
            os_log("❌ %{public}@: %{public}@", log: generalLogger, type: .error, message, error.localizedDescription)
        } else {
            os_log("❌ %{public}@", log: generalLogger, type: .error, message)
        }
    }

    func logWarning(_ message: String) {
        os_log("⚠️ %{public}@", log: generalLogger, type: .fault, message)
    }

    func logInfo(_ message: String) {
        os_log("ℹ️ %{public}@", log: generalLogger, type: .info, message)
    }

    func logDebug(_ message: String) {
        os_log("🐛 %{public}@", log: generalLogger, type: .debug, message)
    }
}
