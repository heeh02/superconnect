import Foundation
import CoreGraphics

/// Keeps the Mac's own (real) displays at the scaled resolution the user had *before* connecting.
///
/// When a virtual display is added, macOS re-normalizes the arrangement and often resets the
/// built-in display's scaled resolution to its default ("looks like" bigger / less space), reverting
/// it only when the virtual display is removed. This guard snapshots every real display's mode at
/// `start()` (called before the virtual display exists) and re-asserts it via a display-reconfiguration
/// callback whenever macOS changes it — so the user's MacBook screen stays exactly as they left it.
public final class DisplayModeGuard {
    private var saved: [CGDirectDisplayID: CGDisplayMode] = [:]
    private var restoring = false
    private var active = false
    /// Guards `saved`/`active`/`restoring` — these are touched from the CG reconfiguration callback
    /// (arbitrary thread), from start()/stop() (lifeQ via retain/release), and from the async restore
    /// block (global queue). Distinct from `refLock` (refcount-only). CG calls are made OUTSIDE this
    /// lock so a reconfiguration callback re-entering during a restore can't deadlock.
    private let stateLock = NSLock()

    public init() {}

    // MARK: - Process-shared, refcounted use (#51 multi-session)

    /// One guard shared across ALL connections. With multiple simultaneous connections the snapshot
    /// must be taken ONCE — before any virtual display exists — and only the real displays pinned;
    /// a per-connection guard started after the first virtual display would wrongly snapshot+pin that
    /// virtual display and fight another connection's rotation. retain()/release() refcount the shared
    /// guard so it starts on the first connect and stops only when the last connection drops.
    public static let shared = DisplayModeGuard()
    private let refLock = NSLock()
    private var refcount = 0

    /// Begin (or join) guarding. Snapshots + registers the callback on the 0→1 transition only.
    public func retain() {
        refLock.lock(); defer { refLock.unlock() }
        if refcount == 0 { start() }
        refcount += 1
    }

    /// Leave guarding. Removes the callback + clears the snapshot on the N→0 transition only.
    public func release() {
        refLock.lock(); defer { refLock.unlock() }
        guard refcount > 0 else { return }
        refcount -= 1
        if refcount == 0 { stop() }
    }

    // MARK: - Direct use (single-use callers / tests)

    /// Snapshot the current (pre-virtual-display) mode of every active display, then start guarding.
    public func start() {
        let modes = Self.activeDisplayModes()   // CG query outside the lock
        stateLock.lock()
        guard !active else { stateLock.unlock(); return }
        saved = modes
        active = true
        stateLock.unlock()
        CGDisplayRegisterReconfigurationCallback(Self.cb, Unmanaged.passUnretained(self).toOpaque())
    }

    public func stop() {
        stateLock.lock()
        guard active else { stateLock.unlock(); return }
        active = false
        saved = [:]
        stateLock.unlock()
        CGDisplayRemoveReconfigurationCallback(Self.cb, Unmanaged.passUnretained(self).toOpaque())
    }

    private static func activeDisplayModes() -> [CGDirectDisplayID: CGDisplayMode] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        var out: [CGDirectDisplayID: CGDisplayMode] = [:]
        for id in ids where CGDisplayCopyDisplayMode(id) != nil { out[id] = CGDisplayCopyDisplayMode(id) }
        return out
    }

    private static func equal(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height &&
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight &&
        abs(a.refreshRate - b.refreshRate) < 0.5
    }

    // Non-capturing → bridges to the C callback pointer; the instance arrives via userInfo.
    private static let cb: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        guard let userInfo else { return }
        Unmanaged<DisplayModeGuard>.fromOpaque(userInfo).takeUnretainedValue().handle(display, flags)
    }

    private func handle(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        guard flags.contains(.setModeFlag), !flags.contains(.beginConfigurationFlag) else { return }
        // Arm the restore under the lock so two back-to-back callbacks can't both pass the guard, and
        // snapshot `want` so the async body never touches `saved` off-lock.
        stateLock.lock()
        guard active, !restoring,
              let want = saved[display],
              let cur = CGDisplayCopyDisplayMode(display), !Self.equal(cur, want) else { stateLock.unlock(); return }
        restoring = true
        stateLock.unlock()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); let stillActive = self.active; self.stateLock.unlock()
            if stillActive {
                var cfg: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&cfg) == .success, let cfg {
                    CGConfigureDisplayWithDisplayMode(cfg, display, want, nil)   // pin back to the user's mode (CG call OFF-lock)
                    _ = CGCompleteDisplayConfiguration(cfg, .forSession)
                }
            }
            self.stateLock.lock(); self.restoring = false; self.stateLock.unlock()
        }
    }
}
