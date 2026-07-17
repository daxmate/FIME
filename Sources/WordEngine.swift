import Foundation

/// 预测引擎层 — 输入控制器与词库之间的薄服务层
///
/// `WordEngine` 是 `FIMEController` 和 `WordDatabase` 之间的桥梁。
/// 它封装了候选词查询和选择频率记录的调用，让控制器不需要直接
/// 与数据库和持久化细节打交道。
final class WordEngine {
    private let database: WordDatabase

    // MARK: - 初始化

    /// 创建预测引擎实例
    /// - Parameter database: 词库实例，负责存储和检索单词
    init(database: WordDatabase) {
        self.database = database
    }

    // MARK: - 公开 API

    /// 根据用户输入返回候选词列表
    ///
    /// 将输入传递给 `WordDatabase.predict(prefix:)` 执行子序列匹配，
    /// 返回按频率和长度排序的候选词。
    ///
    /// - Parameter input: 用户当前输入的字母（如 "pls"）
    /// - Returns: 匹配的候选词数组，最多 8 个，按频率降序、长度升序排列
    func candidates(for input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        return database.predict(prefix: input)
    }

    /// 记录用户选中了某个词
    ///
    /// 调用此方法会：
    /// 1. 增加该词的频率计数
    /// 2. 将频率数据持久化到磁盘
    ///
    /// - Parameter word: 用户选中的单词
    func select(_ word: String) {
        database.recordSelection(word)
        database.saveFrequencies()
    }
}
