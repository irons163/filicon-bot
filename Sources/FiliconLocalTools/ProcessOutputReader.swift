import Darwin
import Foundation

/// One non-blocking read at a time. The next chunk (and EOF) cannot overtake an
/// unacknowledged delivery to the supervisor. At most 64 KiB is in flight per pipe.
/// All mutable fields below are confined to `queue`; the descriptor belongs to
/// the dispatch source until its cancellation handler closes it.
final class LocalProcessOutputReader: @unchecked Sendable {
    enum Event: Sendable { case bytes(Data), closed(LocalToolError?) }
    private let queue = DispatchQueue(label: "filicon.process.output")
    private let source: any DispatchSourceRead
    private let fd: Int32
    private let receive: @Sendable (Event) async -> Void
    private var delivering = false
    private var suspended = false
    private var closed = false
    private var closingError: LocalToolError?

    /// The caller must configure fd as O_NONBLOCK before transferring ownership.
    init(fd: Int32, receive: @escaping @Sendable (Event) async -> Void) {
        self.fd = fd; self.receive = receive
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readReady() }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
    }

    deinit { source.cancel() }

    func stop(error: LocalToolError? = nil) {
        queue.async { self.close(error: error) }
    }

    private func readReady() {
        guard !closed, !delivering else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        var count: Int
        repeat { count = Darwin.read(fd, &bytes, bytes.count) } while count < 0 && errno == EINTR
        if count > 0 {
            source.suspend(); suspended = true; delivering = true
            let data = Data(bytes.prefix(count))
            Task {
                await receive(.bytes(data))
                queue.async { self.didDeliver() }
            }
        } else if count == 0 {
            close(error: nil)
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            close(error: .ioFailure("output read: \(String(cString: strerror(errno)))"))
        }
    }

    private func didDeliver() {
        delivering = false
        if closed { deliverEnd() }
        else if suspended { source.resume(); suspended = false }
    }

    private func close(error: LocalToolError?) {
        guard !closed else { return }
        closed = true; closingError = error
        source.cancel()
        // A suspended dispatch source must be resumed for cancellation/FD close.
        if suspended { source.resume(); suspended = false }
        if !delivering { deliverEnd() }
    }

    private func deliverEnd() {
        let error = closingError, receive = receive
        Task { await receive(.closed(error)) }
    }
}
