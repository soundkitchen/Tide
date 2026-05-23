import Foundation
import os

enum AppLogger {
    static let subsystem = "org.izukawa.Tide"
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let s3 = Logger(subsystem: subsystem, category: "s3")
    static let db = Logger(subsystem: subsystem, category: "database")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let watcher = Logger(subsystem: subsystem, category: "watcher")
}
