import Foundation
import os

public enum AppLogger {
    public static let subsystem = "org.izukawa.Tide"
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let s3 = Logger(subsystem: subsystem, category: "s3")
    public static let db = Logger(subsystem: subsystem, category: "database")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let watcher = Logger(subsystem: subsystem, category: "watcher")
    /// File Provider 拡張（TideFileProvider.appex・M5 Phase 3〜）
    public static let fileProvider = Logger(subsystem: subsystem, category: "fileprovider")
}
