import Foundation
import Network

/// Whether there is any route to the network.
///
/// Used to skip the cloud polisher outright when offline. Without it a dictation
/// made on a plane pays the full 30s request timeout — and, once a long take is
/// split into pieces, pays it once per piece — before falling back.
///
/// Defaults to online and only ever goes false on a definite report from the OS:
/// wrongly skipping the cloud is worse than one wasted request.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.usingcolor.WhisperLocal.reachability")
    private let lock = NSLock()
    private var online = true
    private var started = false

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status != .unsatisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}
