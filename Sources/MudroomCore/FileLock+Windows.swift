#if os(Windows)
import WinSDK
import Foundation

/// An exclusive lock (LockFileEx) on a file, released when the process
/// exits even if it crashes. The Windows counterpart of the flock(2) one
/// in Applier.swift.
public final class FileLock {
    private var handle: HANDLE?

    private init(handle: HANDLE) { self.handle = handle }

    private static func open(_ url: URL, create: Bool) -> HANDLE? {
        let share = DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE)
        let access = create ? DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE) : DWORD(GENERIC_READ)
        let h = Win32.withPath(url.path) {
            CreateFileW($0, access, share, nil, DWORD(create ? OPEN_ALWAYS : OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { return nil }
        return h
    }

    /// Locks the file's first byte without waiting. Locks belong to the
    /// handle, so a second handle in this same process is refused too, as
    /// with flock.
    private static func lock(_ h: HANDLE, exclusive: Bool) -> Bool {
        var overlapped = OVERLAPPED()
        let flags = DWORD(LOCKFILE_FAIL_IMMEDIATELY) | (exclusive ? DWORD(LOCKFILE_EXCLUSIVE_LOCK) : 0)
        return LockFileEx(h, flags, 0, 1, 0, &overlapped)
    }

    private static func unlock(_ h: HANDLE) {
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(h, 0, 1, 0, &overlapped)
    }

    /// Waits up to `waiting` seconds for the lock.
    public static func acquire(_ url: URL, waiting: TimeInterval, what: String) throws -> FileLock {
        guard let h = open(url, create: true) else { throw Win32.error("CreateFileW", url.path, GetLastError()) }
        let deadline = Date().addingTimeInterval(waiting)
        while !lock(h, exclusive: true) {
            guard GetLastError() == DWORD(ERROR_LOCK_VIOLATION), Date() < deadline else {
                CloseHandle(h)
                throw MudroomError.invalid("\(what) is already running; try again when it finishes")
            }
            Sleep(50)
        }
        return FileLock(handle: h)
    }

    /// Takes the lock only if nobody holds it. On Windows the lock is this
    /// process's alone; `inheritable` changes nothing (the sandbox CLI it
    /// starts doesn't keep it held).
    public static func tryAcquire(_ url: URL, inheritable: Bool = false) -> FileLock? {
        guard let h = open(url, create: true) else { return nil }
        guard lock(h, exclusive: true) else {
            CloseHandle(h)
            return nil
        }
        return FileLock(handle: h)
    }

    /// True if some process holds the lock on `url` (false if the file
    /// doesn't exist).
    public static func isHeld(_ url: URL) -> Bool {
        guard let h = open(url, create: false) else { return false }
        defer { CloseHandle(h) }
        if lock(h, exclusive: false) {
            unlock(h)
            return false
        }
        return GetLastError() == DWORD(ERROR_LOCK_VIOLATION)
    }

    public func release() {
        guard let h = handle else { return }
        Self.unlock(h)
        CloseHandle(h)
        handle = nil
    }

    deinit { release() }
}
#endif
