//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

@objcMembers public class NCLog: NSObject {

    private static let backgroundLogQueue = DispatchQueue(label: "\(bundleIdentifier).backgroundLogQueue", qos: .background)

    private static let logLineDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd H:mm:ss.SSSS"

        return dateFormatter
    }()

    private static let fileNameDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return dateFormatter
    }()

    /// Which process wrote a line. The app and its extensions share one logfile, and an extension's
    /// lines are the only record of what happened while the app was not running, so each line has
    /// to say where it came from.
    private static let processTag = ProcessInfo.processInfo.processName

    private static var logfilePath: URL? = {
        let fileManager = FileManager.default

        // The notification extension is a separate process with its own container, so writing to
        // the per-process Documents directory put its lines in a file the app could never show —
        // which is why a push that only ever woke the extension appeared to leave no trace at all.
        // The shared app group container is the one place both can write and the app can read.
        let baseDir = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let baseDir else { return nil }

        let logDir = baseDir.appendingPathComponent("logs")
        let logPath = logDir.path

        // Allow writing to files while the app is in the background
        if !fileManager.fileExists(atPath: logPath) {
            try? fileManager.createDirectory(atPath: logPath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        }

        return logDir
    }()

    public static func log(_ message: String) {
        guard let logfilePath else { return }

        // Determine the queue here, as otherwise it will be always the backgroundQueue
        let currentQueueName = Thread.current.queueName

        backgroundLogQueue.async {
            do {
                let now = Date()

                var logMessage = "\(logLineDateFormatter.string(from: now)) "
                logMessage += "[\(processTag)] (\(currentQueueName)): \(message)\n"

                let dateString = fileNameDateFormatter.string(from: now)
                let logFileName = "debug-\(dateString).log"
                let fullPath = logfilePath.appendingPathComponent(logFileName).path

                // The app and its extensions append to the same file from different processes, so
                // open with O_APPEND: seeking to the end and then writing would let one process
                // overwrite the other's line.
                let descriptor = open(fullPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)

                if descriptor >= 0 {
                    let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                    // UTF-8 will never be nil
                    try fileHandle.write(contentsOf: logMessage.data(using: .utf8)!)
                    try fileHandle.close()
                } else {
                    try logMessage.write(toFile: fullPath, atomically: false, encoding: .utf8)
                }

                NSLog("%@", logMessage)
            } catch {
                NSLog("Exception in NCLog.log: %@", error.localizedDescription)
                NSLog("Message: %@", message)
            }
        }
    }

    public static func getLogfiles() -> [URL] {
        guard let logfilePath else { return [] }

        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(at: logfilePath, includingPropertiesForKeys: nil)
        else { return [] }

        // Sort descending by file name so the most recent logfile is listed first
        return files
            .filter { $0.lastPathComponent.hasPrefix("debug-") && $0.lastPathComponent.hasSuffix(".log") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func removeOldLogfiles() {
        guard let logfilePath else { return }

        let logPath = logfilePath.path
        let fileManager = FileManager.default

        var dayComponent = DateComponents()
        dayComponent.day = -10

        guard let enumerator = fileManager.enumerator(atPath: logPath),
              let thresholdDate = Calendar.current.date(byAdding: dayComponent, to: Date())
        else { return }

        while let file = enumerator.nextObject() as? String {
            let filePathURL = logfilePath.appendingPathComponent(file)
            let filePath = filePathURL.path

            guard let creationDate = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.creationDate] as? Date
            else { continue }

            if creationDate.compare(thresholdDate) == .orderedAscending && file.hasPrefix("debug-") && file.hasSuffix(".log") {
                NSLog("Deleting old logfile %@", filePath)
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
}
