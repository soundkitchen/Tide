import XCTest
import TideCore

/// `FPEventLog`（Issue #83・FP 拡張イベントの追記型 JSONL 共有ストア）の単体テスト。
/// 追記/読込の往復・ローテーション・読込時再検証（壊れ行 / bucket 不一致 / 不正 path /
/// 未知 eventType / 肥大ファイル拒否 / 長さ上限）を固定する。
final class FPEventLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-event-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private var fileURL: URL { dir.appendingPathComponent("events.jsonl") }

    private func makeLog(bucket: String = "b", maxBytes: Int = FPEventLog.defaultMaxBytes) -> FPEventLog {
        FPEventLog(bucket: bucket, fileURL: fileURL, maxBytes: maxBytes)
    }

    // MARK: - 往復

    func testAppendAndLoadRoundtrip() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "Created (3 bytes)")
        await log.append(type: .download, path: "b/c.txt", message: "Materialized (10 bytes)", details: "d")
        await log.append(type: .info, path: nil, message: "Excluded from sync: unsyncable name (kept local)")

        let records = await log.loadRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].eventType, SyncLogEventType.upload.rawValue)
        XCTAssertEqual(records[0].path, "a.txt")
        XCTAssertEqual(records[0].message, "Created (3 bytes)")
        XCTAssertNil(records[0].details)
        XCTAssertEqual(records[1].details, "d")
        XCTAssertNil(records[2].path, "path なしイベント（検証不能名の除外等）も往復する")
        XCTAssertEqual(records[0].bucket, "b")
        // 時系列（古い → 新しい）
        XCTAssertLessThanOrEqual(records[0].timestamp, records[2].timestamp)
    }

    func testNilFileURLIsNoop() async throws {
        let log = FPEventLog(bucket: "b", fileURL: nil)
        await log.append(type: .upload, path: "a.txt", message: "m")
        let records = await log.loadRecords()
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - ローテーション

    func testRotationKeepsCurrentPlusOneGeneration() async throws {
        // 1 レコード ≈ 100+ bytes。maxBytes を小さくして数件でローテーションさせる。
        let log = makeLog(maxBytes: 300)
        for i in 0..<10 {
            await log.append(type: .upload, path: "f\(i).txt", message: "m\(i)")
        }
        let records = await log.loadRecords()
        // 全件は残らない（最古世代は破棄）が、直近は必ず残る。
        XCTAssertLessThan(records.count, 10)
        XCTAssertGreaterThan(records.count, 0)
        XCTAssertEqual(records.last?.message, "m9", "最新レコードは常に生存")
        // 順序は世代跨ぎでも時系列（`.1` → 現行の順で読む）
        let indices = records.map { Int($0.message.dropFirst())! }
        XCTAssertEqual(indices, indices.sorted())
        // ローテーション済みファイルが実在する
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path + ".1"))
    }

    // MARK: - 読込時再検証

    func testBrokenLinesAreSkipped() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "ok1")
        // 壊れ行（書きかけ / ゴミ）を模擬して直接混入
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken json\n".utf8))
        try handle.close()
        await log.append(type: .upload, path: "b.txt", message: "ok2")

        let records = await log.loadRecords()
        XCTAssertEqual(records.map(\.message), ["ok1", "ok2"])
    }

    func testBucketMismatchRecordsAreDropped() async throws {
        let old = makeLog(bucket: "old-bucket")
        await old.append(type: .upload, path: "a.txt", message: "stale")
        let current = makeLog(bucket: "new-bucket")
        await current.append(type: .upload, path: "b.txt", message: "fresh")

        let records = await current.loadRecords()
        XCTAssertEqual(records.map(\.message), ["fresh"], "バケット切替後は旧バケットのイベントを表示しない")
    }

    func testUnsafePathRecordsAreDropped() async throws {
        let log = makeLog()
        // 改ざんを模擬: 直接不正 path のレコード行を書き込む
        let bad = FPEventRecord(
            timestamp: 1, bucket: "b", eventType: "upload",
            path: "../escape.txt", message: "bad")
        var data = try JSONEncoder().encode(bad)
        data.append(0x0A)
        try data.write(to: fileURL)
        await log.append(type: .upload, path: "ok.txt", message: "good")

        let records = await log.loadRecords()
        XCTAssertEqual(records.map(\.message), ["good"])
    }

    func testUnknownEventTypeRecordsAreDropped() async throws {
        let log = makeLog()
        let unknown = FPEventRecord(
            timestamp: 1, bucket: "b", eventType: "future-type",
            path: "a.txt", message: "unknown")
        var data = try JSONEncoder().encode(unknown)
        data.append(0x0A)
        try data.write(to: fileURL)
        await log.append(type: .info, path: "a.txt", message: "known")

        let records = await log.loadRecords()
        XCTAssertEqual(records.map(\.message), ["known"])
    }

    func testOversizedFileIsRejectedEntirely() async throws {
        // 改ざんによる肥大ファイル（> 2×maxBytes）は読込ごと拒否（メモリ肥大防止）。
        let log = makeLog(maxBytes: 200)
        var blob = Data()
        let filler = try JSONEncoder().encode(
            FPEventRecord(timestamp: 1, bucket: "b", eventType: "upload", path: "a.txt", message: "x"))
        while blob.count <= 400 {
            blob.append(filler)
            blob.append(0x0A)
        }
        try blob.write(to: fileURL)

        let records = await log.loadRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testLongMessageAndDetailsAreTruncatedOnLoad() async throws {
        let log = makeLog()
        let record = FPEventRecord(
            timestamp: 1, bucket: "b", eventType: "error", path: "a.txt",
            message: String(repeating: "m", count: 2_000),
            details: String(repeating: "d", count: 100_000))
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        try data.write(to: fileURL)

        let records = await log.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].message.count, FPEventLog.maxMessageLength)
        XCTAssertEqual(records[0].details?.count, FPEventLog.maxDetailsLength)
    }

    // MARK: - 通知の印（Issue #147）

    func testNoticeRoundtrip() async throws {
        let log = makeLog()
        await log.append(type: .info, path: "a/link", message: "m", notice: .symbolicLink)
        await log.append(type: .upload, path: "b.txt", message: "m")

        let records = await log.loadRecords()
        XCTAssertEqual(records.map(\.notice), [FPEventNotice.symbolicLink.rawValue, nil])
    }

    /// #147 より前の行（notice キーが無い）はそのまま読め、印は nil。
    func testRecordWithoutNoticeKeyDecodes() async throws {
        let log = makeLog()
        let line = #"{"timestamp":1,"bucket":"b","eventType":"info","path":"a.txt","message":"m"}"#
        try Data((line + "\n").utf8).write(to: fileURL)

        let records = await log.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].notice)
    }

    /// 未知の印はレコードごと捨てず、印だけ外す（表示には使える）。
    func testUnknownNoticeIsClearedButRecordKept() async throws {
        let log = makeLog()
        var data = try JSONEncoder().encode(FPEventRecord(
            timestamp: 1, bucket: "b", eventType: "info", path: "a.txt", message: "m", notice: "bogus"))
        data.append(0x0A)
        try data.write(to: fileURL)

        let records = await log.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].notice)
    }

    // MARK: - 差分読み（Issue #148）

    private func messages(_ records: [FPEventRecord]) -> [String] { records.map(\.message) }

    /// 初回は全部、2 回目からは新着だけを読む。新着が無ければ空で位置は動かない。
    func testReadNewReturnsOnlyNewRecords() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "m1")
        await log.append(type: .upload, path: "b.txt", message: "m2")
        let first = await log.readNew(since: nil)
        XCTAssertEqual(messages(first.records), ["m1", "m2"])

        let none = await log.readNew(since: first.position)
        XCTAssertTrue(none.records.isEmpty)
        XCTAssertEqual(none.position, first.position)

        await log.append(type: .upload, path: "c.txt", message: "m3")
        let second = await log.readNew(since: first.position)
        XCTAssertEqual(messages(second.records), ["m3"])
    }

    /// ファイルが無ければ空で、位置は渡したまま。
    func testReadNewWithoutFileKeepsPosition() async throws {
        let log = makeLog()
        let result = await log.readNew(since: nil)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertNil(result.position)
    }

    /// 前回読んだあとにローテーションしても、`.1` の残りと新しい現行を読み、取りこぼさない。
    func testReadNewFollowsRotation() async throws {
        let log = makeLog(maxBytes: 150)
        await log.append(type: .upload, path: "f0.txt", message: "m0")
        let first = await log.readNew(since: nil)
        XCTAssertEqual(messages(first.records), ["m0"])
        // 1 レコード ≈ 95 bytes。m1 の追記でローテーション（現行 → .1）し、m2 は新しい現行へ入る
        await log.append(type: .upload, path: "f1.txt", message: "m1")
        await log.append(type: .upload, path: "f2.txt", message: "m2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path + ".1"))
        let second = await log.readNew(since: first.position)
        XCTAssertEqual(messages(second.records), ["m1", "m2"])
        let third = await log.readNew(since: second.position)
        XCTAssertTrue(third.records.isEmpty)
    }

    /// ローテーションの直後（新しい現行がまだ無い）も `.1` の残りを読み、次の追記で現行へ移る。
    func testReadNewRightAfterRotation() async throws {
        let log = makeLog(maxBytes: 150)
        await log.append(type: .upload, path: "f0.txt", message: "m0")
        let first = await log.readNew(since: nil)
        await log.append(type: .upload, path: "f1.txt", message: "m1")  // ここでローテーション
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let second = await log.readNew(since: first.position)
        XCTAssertEqual(messages(second.records), ["m1"])
        await log.append(type: .upload, path: "f2.txt", message: "m2")
        let third = await log.readNew(since: second.position)
        XCTAssertEqual(messages(third.records), ["m2"])
    }

    /// 改行で終わっていない末尾の行（書きかけ）は読まず、書き終わったら次回に読む。
    func testReadNewLeavesPartialLineForNextRead() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "m1")
        let line = try JSONEncoder().encode(
            FPEventRecord(timestamp: 2, bucket: "b", eventType: "upload", path: "b.txt", message: "m2"))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(10))
        let first = await log.readNew(since: nil)
        XCTAssertEqual(messages(first.records), ["m1"])
        try handle.write(contentsOf: line.dropFirst(10) + [0x0A])
        try handle.close()
        let second = await log.readNew(since: first.position)
        XCTAssertEqual(messages(second.records), ["m2"])
    }

    /// 現行が位置より短くなった（作り直された）ら頭から読む。
    func testReadNewRereadsWhenFileShrinks() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "m1")
        await log.append(type: .upload, path: "b.txt", message: "m2")
        let first = await log.readNew(since: nil)
        // 同じ inode のまま短くする
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        await log.append(type: .upload, path: "c.txt", message: "m3")
        let second = await log.readNew(since: first.position)
        XCTAssertEqual(messages(second.records), ["m3"])
    }

    /// 位置がどのファイルとも合わない（2 回以上ローテーションした）ら、残っている世代を頭から読む。
    func testReadNewRereadsAllWhenPositionIsUnknown() async throws {
        let log = makeLog()
        await log.append(type: .upload, path: "a.txt", message: "m1")
        let result = await log.readNew(since: FPEventLog.ReadPosition(inode: 0, offset: 12_345))
        XCTAssertEqual(messages(result.records), ["m1"])
    }

    /// 差分読みも読込時の再検証（bucket 不一致・不正 path）を通す。
    func testReadNewValidatesRecords() async throws {
        await makeLog(bucket: "other").append(type: .upload, path: "x.txt", message: "other bucket")
        let log = makeLog()
        await log.append(type: .upload, path: "../escape", message: "bad path")
        await log.append(type: .upload, path: "ok.txt", message: "ok")
        let result = await log.readNew(since: nil)
        XCTAssertEqual(messages(result.records), ["ok"])
    }

    /// 通知に出す名前: symlink は path、それ以外は details（表示用のパス）。
    func testNoticeSubject() {
        let record = FPEventRecord(
            timestamp: 1, bucket: "b", eventType: "info", path: "old/name.txt", message: "m",
            details: "new/name.env")
        XCTAssertEqual(FPEventNotice.symbolicLink.subject(of: record), "old/name.txt")
        XCTAssertEqual(FPEventNotice.unsyncableName.subject(of: record), "new/name.env")
        XCTAssertEqual(FPEventNotice.renamedFileExcluded.subject(of: record), "new/name.env")
        XCTAssertEqual(FPEventNotice.renamedFolderExcluded.subject(of: record), "new/name.env")
    }
}
