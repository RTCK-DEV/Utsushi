import Foundation

/// 同時実行数に上限を付けた並行 map。結果は必ず入力の順序で返す。
///
/// Foundation Models の呼び出しは 1 回ごとに新しいセッションを作る実装なので
/// 並行に投げられるが、無制限に打ち上げると百件単位のセッションが同時に立つ。
/// 上限はスループットではなく同時セッション数を抑えるためにある。
enum BoundedParallel {
    /// `work` が nil を返した要素は結果から抜ける（順序は残り要素で保持される）。
    static func compactMap<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        concurrency: Int,
        progress: (@Sendable (Int) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        _ work: @escaping @Sendable (Item) async -> Result?
    ) async -> [Result] {
        guard !items.isEmpty else { return [] }
        var slots = [Result?](repeating: nil, count: items.count)
        let done = LockedCounter()
        let limit = max(1, min(concurrency, items.count))
        await withTaskGroup(of: (Int, Result?).self) { group in
            var it = items.enumerated().makeIterator()
            var inFlight = 0
            while inFlight < limit, let (i, item) = it.next() {
                group.addTask { (i, await work(item)) }
                inFlight += 1
            }
            while let (i, r) = await group.next() {
                slots[i] = r
                inFlight -= 1
                progress?(done.increment())
                while inFlight < limit, !isCancelled(), let (j, item) = it.next() {
                    group.addTask { (j, await work(item)) }
                    inFlight += 1
                }
            }
        }
        return slots.compactMap { $0 }
    }
}

/// @Sendable クロージャの中から安全にインクリメントするための小さい箱。
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}
