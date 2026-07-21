import Foundation

struct LoopSecondRange: Equatable {
    static let allowedSeconds = 1...86_400

    let minimum: Int
    let maximum: Int

    init?(minimum: Int, maximum: Int) {
        guard
            Self.allowedSeconds.contains(minimum),
            Self.allowedSeconds.contains(maximum),
            minimum <= maximum
        else {
            return nil
        }

        self.minimum = minimum
        self.maximum = maximum
    }

    func randomDelayNanoseconds() -> UInt64 {
        // 每轮重新抽取整数秒；转成纳秒后直接交给可取消的 Task.sleep。
        UInt64(Int.random(in: minimum...maximum)) * 1_000_000_000
    }
}
