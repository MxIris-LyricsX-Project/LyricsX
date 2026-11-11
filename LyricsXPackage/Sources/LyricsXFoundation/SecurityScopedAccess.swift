import Foundation

/// Retain for the duration of an asynchronous operation that needs directory access.
/// Releasing the instance relinquishes only the access acquired by this instance.
public final class SecurityScopedAccess: Sendable {
    private let directoryURL: URL?

    public init(to directoryURL: URL?, permissionError: CocoaError.Code = .fileReadNoPermission) throws {
        if let directoryURL, !directoryURL.startAccessingSecurityScopedResource() {
            throw CocoaError(permissionError)
        }
        self.directoryURL = directoryURL
    }

    deinit {
        directoryURL?.stopAccessingSecurityScopedResource()
    }
}

/// Keeps a granted directory accessible until the operation returns or throws.
/// A nil URL performs the operation without requesting a security scope.
public func withSecurityScopedAccess<Result>(
    to directoryURL: URL?,
    permissionError: CocoaError.Code = .fileReadNoPermission,
    perform operation: () throws -> Result
) throws -> Result {
    let access = try SecurityScopedAccess(to: directoryURL, permissionError: permissionError)
    return try withExtendedLifetime(access, operation)
}
