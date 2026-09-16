import Darwin
import Foundation

public final class AgentOwnershipLock {
    private var descriptor: Int32 = -1
    private let url: URL

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/st.rio.virt-connectord/ownership.lock")
    }

    public init(url: URL = AgentOwnershipLock.defaultURL) {
        self.url = url
    }

    public func acquire() throws -> Bool {
        precondition(descriptor == -1)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        return true
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
