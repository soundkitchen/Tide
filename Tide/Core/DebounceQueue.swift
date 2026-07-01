import TideCore
import Foundation

/// 同一キー（パス）のイベントを最後の到着から `interval` 秒間無音になるまで集約する。
/// 最新の値を flush 時に出力する。
actor DebounceQueue<Value: Sendable> {
    private let interval: Duration
    private var pending: [String: (value: Value, task: Task<Void, Never>)] = [:]
    private let emitter: @Sendable (String, Value) async -> Void

    init(interval: TimeInterval, onFlush: @Sendable @escaping (String, Value) async -> Void) {
        self.interval = .nanoseconds(Int(interval * 1_000_000_000))
        self.emitter = onFlush
    }

    func submit(key: String, value: Value) {
        pending[key]?.task.cancel()
        let task = Task { [weak self, interval] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.fire(key: key)
        }
        pending[key] = (value, task)
    }

    func flushAll() {
        let snapshot = pending
        pending.removeAll()
        for (_, entry) in snapshot {
            entry.task.cancel()
        }
        let emitter = self.emitter
        for (key, entry) in snapshot {
            let value = entry.value
            Task.detached {
                await emitter(key, value)
            }
        }
    }

    /// timer task の延長で呼ばれる。前段の submit が同 key を上書き cancel する競合が起きると
    /// このコンテキスト自体が cancelled 状態のまま走ることがあるため、emitter は detached で隔離する。
    private func fire(key: String) {
        guard let entry = pending.removeValue(forKey: key) else { return }
        let emitter = self.emitter
        let value = entry.value
        Task.detached {
            await emitter(key, value)
        }
    }
}
