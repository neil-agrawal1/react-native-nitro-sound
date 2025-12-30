
import Foundation

/// Thread-safe file logger for debugging overnight sessions
/// Writes timestamped logs to Documents/debug_logs/
class FileLogger {
    static let shared = FileLogger()

    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.dust.filelogger", qos: .utility)
    private var logFileHandle: FileHandle?
    private var currentLogFile: URL?
    private var userIdentifier: String = "anonymous"

    // Session statistics for summary
    private var errorCount: Int = 0
    private var warningCount: Int = 0
    private var sessionStartTime: Date = Date()

    private init() {
        setupLogFile()
    }

    deinit {
        // Write session summary before closing
        writeSessionSummarySync()
        try? logFileHandle?.close()
    }

    /// Set the user identifier for log file naming
    /// This will be used when creating new log files (on next app restart)
    func setUserIdentifier(_ identifier: String) {
        logQueue.async { [weak self] in
            self?.userIdentifier = identifier.isEmpty ? "anonymous" : identifier
        }
    }

    /// Get the logs directory URL
    private func getLogsDirectory() -> URL? {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsURL.appendingPathComponent("debug_logs")
    }

    /// Setup log file for current session
    private func setupLogFile() {
        logQueue.async { [weak self] in
            guard let self = self,
                  let logsDir = self.getLogsDirectory() else {
                return
            }

            // Create logs directory if needed
            if !self.fileManager.fileExists(atPath: logsDir.path) {
                try? self.fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
            }

            // Create log file with user identifier and timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMd_h-mma"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
            let timestamp = formatter.string(from: Date())

            // Sanitize user identifier for filename (remove special chars)
            let safeIdentifier = self.userIdentifier.replacingOccurrences(
                of: "[^a-zA-Z0-9]",
                with: "",
                options: .regularExpression
            )
            let filename = "\(safeIdentifier)_debug_\(timestamp).log"
            let fileURL = logsDir.appendingPathComponent(filename)

            // Create file if it doesn't exist
            if !self.fileManager.fileExists(atPath: fileURL.path) {
                self.fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            // Open file handle for appending
            self.logFileHandle = try? FileHandle(forWritingTo: fileURL)
            self.logFileHandle?.seekToEndOfFile()
            self.currentLogFile = fileURL

            // Clean old logs (keep last 7 days)
            self.cleanOldLogs()

            // Reset session statistics
            self.errorCount = 0
            self.warningCount = 0
            self.sessionStartTime = Date()

            // Write session start marker with timezone info
            let timezone = TimeZone.current
            let utcOffset = timezone.secondsFromGMT() / 3600
            let timezoneInfo = "\(timezone.identifier) (UTC\(utcOffset >= 0 ? "+" : "")\(utcOffset))"
            self.writeToFile("========== SESSION START ==========\n")
            self.writeToFile("Time: \(Date())\n")
            self.writeToFile("Timezone: \(timezoneInfo)\n")
            self.writeToFile("===================================\n")
        }
    }

    /// Write log message to file
    func log(_ message: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            // Wait for file handle to be ready (setup runs async on first access)
            // This prevents early logs from being lost during initialization
            var attempts = 0
            while self.logFileHandle == nil && attempts < 50 {
                Thread.sleep(forTimeInterval: 0.01) // Wait 10ms per attempt (max 500ms total)
                attempts += 1
            }

            self.writeToFile(message)
        }
    }

    /// Internal write method (must be called on logQueue)
    private func writeToFile(_ message: String) {
        guard let handle = logFileHandle else {
            return
        }

        // Track error/warning counts for session summary
        if message.contains("[ERROR]") {
            errorCount += 1
        } else if message.contains("[WARN]") {
            warningCount += 1
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        let logLine = "[\(timestamp)] \(message)\n"

        if let data = logLine.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    /// Get path to current log file
    func getCurrentLogPath() -> String? {
        return currentLogFile?.path
    }

    /// Get all log file paths (sorted by date, newest first)
    func getAllLogPaths() -> [String] {
        guard let logsDir = getLogsDirectory() else {
            return []
        }

        guard let files = try? fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let logFiles = files.filter { $0.pathExtension == "log" }

        // Sort by creation date, newest first
        let sorted = logFiles.sorted { file1, file2 in
            let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 > date2
        }

        return sorted.map { $0.path }
    }

    /// Read contents of current log file
    func readCurrentLog() -> String? {
        guard let filePath = currentLogFile?.path else {
            return nil
        }
        return try? String(contentsOfFile: filePath, encoding: .utf8)
    }

    /// Read contents of specific log file
    func readLog(at path: String) -> String? {
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Clear all logs
    func clearAllLogs() {
        logQueue.async { [weak self] in
            guard let self = self,
                  let logsDir = self.getLogsDirectory() else {
                return
            }

            // Close current file handle
            try? self.logFileHandle?.close()
            self.logFileHandle = nil
            self.currentLogFile = nil

            // Delete all log files
            if let files = try? self.fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "log" {
                    try? self.fileManager.removeItem(at: file)
                }
            }

            // Re-setup log file
            self.setupLogFile()
        }
    }

    /// Clean logs older than 7 days
    private func cleanOldLogs() {
        guard let logsDir = getLogsDirectory() else {
            return
        }

        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        guard let files = try? fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for file in files where file.pathExtension == "log" {
            if let creationDate = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               creationDate < sevenDaysAgo {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Session Summary

    /// Write session summary (async, thread-safe)
    /// Call this when the app is backgrounding or before generating a bug report
    func writeSessionSummary() {
        logQueue.async { [weak self] in
            self?.writeSessionSummaryInternal()
        }
    }

    /// Write session summary synchronously (for deinit)
    private func writeSessionSummarySync() {
        logQueue.sync { [weak self] in
            self?.writeSessionSummaryInternal()
        }
    }

    /// Internal implementation of session summary writing
    private func writeSessionSummaryInternal() {
        guard logFileHandle != nil else { return }

        let sessionDuration = Date().timeIntervalSince(sessionStartTime)
        let hours = Int(sessionDuration) / 3600
        let minutes = (Int(sessionDuration) % 3600) / 60
        let seconds = Int(sessionDuration) % 60

        let durationString: String
        if hours > 0 {
            durationString = "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            durationString = "\(minutes)m \(seconds)s"
        } else {
            durationString = "\(seconds)s"
        }

        // Create a visually distinct summary block
        var summary = "\n"
        summary += "=========== SESSION SUMMARY ===========\n"
        summary += "Duration: \(durationString)\n"

        // Errors and warnings with visual indicators
        if errorCount > 0 {
            summary += "🔴 ERRORS: \(errorCount)\n"
        } else {
            summary += "✅ ERRORS: 0\n"
        }

        if warningCount > 0 {
            summary += "🟡 WARNINGS: \(warningCount)\n"
        } else {
            summary += "✅ WARNINGS: 0\n"
        }

        // Overall status
        if errorCount == 0 && warningCount == 0 {
            summary += "Status: Clean session - no issues detected\n"
        } else if errorCount > 0 {
            summary += "Status: ⚠️ Session had \(errorCount) error(s) - review above\n"
        } else {
            summary += "Status: Session had \(warningCount) warning(s)\n"
        }

        summary += "=======================================\n"

        // Write directly without timestamp prefix (summary is self-contained)
        if let data = summary.data(using: .utf8) {
            try? logFileHandle?.write(contentsOf: data)
        }
    }
}
