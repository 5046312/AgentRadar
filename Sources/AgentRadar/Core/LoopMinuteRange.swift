import Foundation

struct LoopMinuteRange: Equatable {
    static let allowedMinutes = 1...1_440

    let minimum: Int
    let maximum: Int

    init?(minimum: Int, maximum: Int) {
        guard
            Self.allowedMinutes.contains(minimum),
            Self.allowedMinutes.contains(maximum),
            minimum <= maximum
        else {
            return nil
        }

        self.minimum = minimum
        self.maximum = maximum
    }

    func randomDelayNanoseconds() -> UInt64 {
        // 每轮重新抽取整数分钟；转成纳秒后直接交给可取消的 Task.sleep。
        UInt64(Int.random(in: minimum...maximum)) * 60 * 1_000_000_000
    }
}
