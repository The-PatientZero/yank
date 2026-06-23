import os

/// Categorised logging over os.Logger, replacing ad-hoc print() debugging.
enum Log {
    private static let subsystem = "com.thepatientzero.yank"
    static let store   = Logger(subsystem: subsystem, category: "store")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let hotkey  = Logger(subsystem: subsystem, category: "hotkey")
    static let update  = Logger(subsystem: subsystem, category: "update")
    static let ocr     = Logger(subsystem: subsystem, category: "ocr")
    static let paste   = Logger(subsystem: subsystem, category: "paste")
    static let app     = Logger(subsystem: subsystem, category: "app")
}
