import Foundation
import Darwin

/// 两个 app 路径同时被打开时，也只有一个进程会定时查询；进程退出后内核释放锁。
final class SingleInstanceLock {
    private var descriptor: Int32 = -1
    func acquire() -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Board", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        descriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1; return false
        }
        return true
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
}
