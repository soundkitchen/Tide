import Foundation

/// トークンバケットの純粋計算（時刻取得・`Task.sleep` から切り離してテスト可能にする。
/// `StabilityCheck` / `PartPlan` と同じパターン）。
///
/// **予約（負残高許容）方式**: `reserve(n)` は要求バイト `n` を即座に残高から差し引き（負になり得る）、
/// 「残高が 0 以上へ回復するまでの待ち秒」を返す。呼び出し側（`RateLimiter`）はその秒数だけ待ってから
/// 次へ進む。先に差し引くので並行呼び出しでも公平（到着順に直列化され、後続は先行分の負債も含めて待つ）に
/// なり、総スループットが `ratePerSec` に収束する。バーストは「アイドル中に貯まるトークン上限 = `burst`」で
/// 抑える（補充時のみ cap・負債側は cap しない）。`ratePerSec <= 0` は無制限（常に待ち 0・残高を触らない）。
struct TokenBucket: Sendable {
    /// 補充レート（bytes/sec）。`<= 0` は無制限。
    private(set) var ratePerSec: Double
    /// 補充時にトークンが貯まる上限（bytes）。アイドル後に許すバースト量。
    private(set) var burst: Double
    /// 現在のトークン残高（bytes）。予約で負になり得る。
    private(set) var tokens: Double
    /// 最後に補充・予約した時刻（秒・単調時計）。
    private(set) var lastUpdate: Double

    init(ratePerSec: Double, now: Double) {
        let r = max(0, ratePerSec)
        self.ratePerSec = r
        self.burst = Self.burst(for: r)
        self.tokens = self.burst
        self.lastUpdate = now
    }

    /// レートに対するバースト上限（1 秒ぶんのトークンを許す）。
    private static func burst(for ratePerSec: Double) -> Double {
        ratePerSec
    }

    /// `now` まで補充だけ行う（レート変更や予約の前段）。`ratePerSec <= 0` のときは何もしない。
    private mutating func refill(now: Double) {
        guard ratePerSec > 0 else { lastUpdate = now; return }
        let elapsed = max(0, now - lastUpdate)
        tokens = min(burst, tokens + elapsed * ratePerSec)
        lastUpdate = now
    }

    /// `n` バイトを予約し、残高が 0 以上へ回復するまでの待ち秒を返す（`<= 0` は即時可）。
    /// 無制限（`ratePerSec <= 0`）は常に 0 を返し、残高を触らない。
    mutating func reserve(_ n: Double, now: Double) -> Double {
        guard ratePerSec > 0 else { return 0 }
        refill(now: now)
        tokens -= max(0, n)                 // 予約（負になり得る）
        if tokens >= 0 { return 0 }
        return -tokens / ratePerSec         // n > burst でも比例待ち＝デッドロックしない
    }

    /// レートを変更する（無制限 ⇄ 制限の切替を含む）。変更前に旧レートで補充を確定させる。
    mutating func setRate(_ newRatePerSec: Double, now: Double) {
        let newRate = max(0, newRatePerSec)
        if ratePerSec > 0 {
            refill(now: now)                // 旧レートぶんを確定
        } else {
            lastUpdate = now
        }
        let wasUnlimited = ratePerSec <= 0
        ratePerSec = newRate
        burst = Self.burst(for: newRate)
        if newRate <= 0 {
            tokens = 0
        } else if wasUnlimited {
            tokens = burst                  // 無制限→制限: 1 秒ぶんから開始
        } else {
            tokens = min(tokens, burst)     // 新バーストを超える貯蓄は持ち越さない（負債はそのまま）
        }
    }
}

/// バイト単位のトークンバケット帯域制御（アップロード／ダウンロードの転送経路で共有する actor）。
///
/// `acquire(_:)` を「次に送る／受け取るバイト数」の直前に呼ぶと、設定レート（bytes/sec）に
/// スループットを律速する。複数の並行転送（マルチパートの並列パート・複数ファイル並行 DL/UL）が
/// **同一インスタンスを共有**することで、合計が上限に収まる（個人利用の背景帯域制限が目的）。
/// レート `<= 0` は無制限（`acquire` は即返る）。`SyncEngine` が config から `setRate` で更新する。
actor RateLimiter {
    private var bucket: TokenBucket

    init(ratePerSec: Double) {
        self.bucket = TokenBucket(ratePerSec: ratePerSec, now: Self.nowSeconds())
    }

    /// 単調時計（壁時計の巻き戻り・NTP 調整の影響を受けない）。
    private static func nowSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// 現在のレート（bytes/sec）。`<= 0` は無制限。
    var ratePerSec: Double { bucket.ratePerSec }

    /// レートを更新する（bytes/sec、`<= 0` で無制限）。
    func setRate(_ ratePerSec: Double) {
        bucket.setRate(ratePerSec, now: Self.nowSeconds())
    }

    /// `n` バイトを送受信する許可を取る。必要なら設定レートに見合うだけ待つ。
    /// 無制限・`n <= 0` のときは即返る。キャンセルされても（`Task.sleep` の throw を飲んで）転送は止めない。
    func acquire(_ n: Int) async {
        guard n > 0 else { return }
        let wait = bucket.reserve(Double(n), now: Self.nowSeconds())
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1_000_000_000))
        }
    }
}
