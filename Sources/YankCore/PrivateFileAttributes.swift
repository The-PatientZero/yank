import Foundation

enum PrivateFileAttributes {
    static func apply(
        to url: URL,
        permissions: Int?,
        protection: FileProtectionType?
    ) throws {
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }

        guard let protection else { return }
        do {
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        } catch where isUnsupportedFileProtectionError(error) {
            // macOS file-protection classes are filesystem-dependent. Keep the strict
            // POSIX permissions above, but do not fail persistence on volumes that reject
            // NSFileProtection attributes.
        }
    }

    private static func isUnsupportedFileProtectionError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if isUnsupportedPOSIXCode(nsError) { return true }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isUnsupportedPOSIXCode(underlying)
    }

    private static func isUnsupportedPOSIXCode(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain && (error.code == EINVAL || error.code == ENOTSUP)
    }
}
