import Foundation

protocol SessionTimerDriving: AnyObject {
    func arm(token: UInt64, fire: @escaping (UInt64) -> Void)
    func cancel(token: UInt64)
}

final class DispatchSessionTimerDriver: SessionTimerDriving {
    private let queue = DispatchQueue(label: "superconnect.session.timer")
    private var current: (UInt64, DispatchWorkItem)?

    func arm(token: UInt64, fire: @escaping (UInt64) -> Void) {
        precondition(current == nil && token != 0)
        let item = DispatchWorkItem { fire(token) }
        current = (token, item)
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    func cancel(token: UInt64) {
        guard current?.0 == token else { return }
        current?.1.cancel()
        current = nil
    }
}
