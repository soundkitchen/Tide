import Foundation

/// pull と restore が「リモート由来の内容を同一 path のローカル FS へ書き込む」フェーズで
/// 同時に走らないよう直列化する、MainActor 上の非再入 async ロック（#34 / D5）。
///
/// `SyncEngine` の旧 pull 単一ゲート（`isRemotePulling` の bool 1 個）を一般化したもの。
/// 1 本のゲートで 2 つの取得セマンティクスを提供する:
/// - `tryAcquire()` … 待たない。保持中なら `false`（pull が busy 時にドロップ/pending するため）。
/// - `acquire()` … 取得できるまで FIFO で待つ（restore が in-flight pull / 先行 restore の完了を待つため）。
///
/// `@MainActor` 隔離なので `tryAcquire` / `release` は同期 ＝ check→set の間に await が無く割り込まれない
/// （旧 bool ゲートと同じ原子性）。`acquire` は保持中なら継続をキューに積んでサスペンドする。
///
/// 注（キャンセル）: 待機中（`acquire` のサスペンド中）の Task キャンセルは伝播しない
/// （`CancellationError` を投げず、順番が来たら lock を引き継いで復帰する）。保持側は必ず `release` するので
/// 待機が永久に残ることはなく、キャンセルされた呼び元も取得直後に自身の処理側でキャンセルを観測して
/// 速やかに `release` する。restore は UI からの単発操作で待機列が深くならないため、この単純さで十分。
@MainActor
final class RemoteOpGate {
    private var locked = false
    /// `acquire()` で順番待ちしている呼び元の継続（FIFO）。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 保持されていなければ取得して `true`。保持中なら `false`（待たない）。
    /// pull が busy 時にドロップ/pending するための非ブロッキング取得。
    func tryAcquire() -> Bool {
        if locked { return false }
        locked = true
        return true
    }

    /// 取得できるまで待つ（FIFO）。restore が in-flight pull / 先行 restore の完了を待つための取得。
    /// 復帰時には lock を保持している（`release()` から所有権を引き継ぐ）。
    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // ここに到達した時点で release() から lock 所有権を引き継いでいる（locked は true のまま）。
    }

    /// 解放。待機者がいれば先頭へ所有権を引き渡す（`locked` を保ったまま resume）。いなければ解放する。
    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
