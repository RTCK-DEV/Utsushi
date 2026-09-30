import Foundation

/// C のオブジェクトポインタ（whisper_context / sherpa recognizer）の所有者。
///
/// actor の deinit からは isolated state に触れられず、かつアプリ終了時には
/// 任意のスレッドから解放したいので、ロック付きのクラスで持つ。
///
/// C 呼び出しが走っている間に free されると use-after-free になるので、
/// 呼び出しの間は `acquire`/`release` で「使用中」にする。
/// 解放側は inUse が 0 になるのを待つ。終了時は AppModel が先に
/// pipeline.cancel() を立てるので、abort_callback が効いていれば
/// C 呼び出しは速やかに戻る。それでも戻らない場合は context を残したまま
/// 諦める（終了時のリークの方が use-after-free より安全）。
final class NativeObjectBox: @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var inUse = 0
    private let cond = NSCondition()
    private let destroy: (OpaquePointer) -> Void

    init(destroy: @escaping (OpaquePointer) -> Void) {
        self.destroy = destroy
    }

    var pointer: OpaquePointer? {
        cond.lock(); defer { cond.unlock() }
        return ptr
    }

    /// C 呼び出しの実行区間だけ「使用中」にする。返したら release。
    func acquire() -> OpaquePointer? {
        cond.lock(); defer { cond.unlock() }
        guard let p = ptr else { return nil }
        inUse += 1
        return p
    }

    func release() {
        cond.lock()
        inUse -= 1
        cond.signal()
        cond.unlock()
    }

    func set(_ p: OpaquePointer) {
        cond.lock()
        waitIdleLocked()
        if inUse == 0, let old = ptr { destroy(old) }
        ptr = p
        cond.unlock()
    }

    func free() {
        cond.lock()
        waitIdleLocked()
        if inUse == 0, let p = ptr { destroy(p); ptr = nil }
        cond.unlock()
    }

    private func waitIdleLocked() {
        let deadline = Date().addingTimeInterval(30)
        while inUse > 0 && Date() < deadline {
            cond.wait(until: Date().addingTimeInterval(0.5))
        }
    }

    deinit { free() }
}
