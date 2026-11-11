/**
 * 采集接收、锁屏作废与背压计数：主线程只移交有界快照，写入在存储 actor。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import OSLog

@MainActor
extension ClipboardLibrary {
    /// 主线程只移交有界快照；哈希、去重、写文件和关系操作都在 actor 上执行。
    func accept(_ capture: ClipCapture) {
        guard recordingEnabled, !paused, !captureBusy, !clearing,
              !(monitor?.isCaptureBlocked() ?? false) else { skippedChange(); return }
        captureBusy = true
        let generation = captureGeneration
        let days = retention
        captureTask = Task { [weak self, store] in
            guard let self else { return }
            // 锁屏、暂停或清空可能发生在排队之后；保存前比对隐私代数。
            guard generation == self.captureGeneration,
                  !(self.monitor?.isCaptureBlocked() ?? false) else {
                self.captureBusy = false
                self.captureTask = nil
                return
            }
            do {
                try await store.save(capture, retention: days)
                // 保存期间锁屏或清空时，保存无法回滚，但不能再刷新列表暴露内容。
                let invalidated = generation != self.captureGeneration
                self.captureBusy = false
                self.captureTask = nil
                guard !invalidated else { return }
                if self.panelVisible { self.scheduleSearch() }
            } catch {
                let invalidated = generation != self.captureGeneration
                self.captureBusy = false
                self.captureTask = nil
                guard !invalidated else { return }
                self.report(error)
            }
        }
    }

    /// 锁屏时作废已接收但尚未落盘的快照；在途任务结束前保持 captureBusy，避免旧保存与新采集交叉。
    /// 已进入 SQLite 事务的保存无法回滚。
    func invalidatePendingCapture() {
        captureGeneration &+= 1
        guard let captureTask else {
            captureBusy = false
            return
        }
        captureTask.cancel()
    }

    func skippedChange() {
        skippedChanges += 1
        logger.notice("Capture skipped under backpressure; count: \(self.skippedChanges)")
    }
}
