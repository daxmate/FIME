import Foundation

/// 词库管理器 — 负责单词加载、子序列匹配、频率跟踪和持久化
///
/// `WordDatabase` 是 FIME 的数据层，负责：
/// - 从资源文件或系统词典加载单词列表
/// - 执行子序列匹配算法（如 "pls" → "please"）
/// - 跟踪用户选择频率并排序
/// - 将频率数据持久化到 `~/.fime_frequencies.json`
final class WordDatabase {
    /// 加载的单词列表（小写）
    private var words: [String] = []

    /// 用户选择频率表，键为小写单词，值为选择次数
    private var frequencies: [String: Int] = [:]

    /// 最大加载词数
    private let maxWords = 3000

    /// 频率持久化文件路径：`~/.fime_frequencies.json`
    private let frequencyURL: URL

    // MARK: - 初始化

    /// 初始化词库管理器
    ///
    /// 调用时自动：
    /// 1. 设置频率文件的 URL
    /// 2. 加载单词列表（优先从资源文件，其次系统词典）
    /// 3. 加载历史频率数据
    init() {
        frequencyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fime_frequencies.json")

        loadWordList()
        loadFrequencies()
    }

    // MARK: - 公开 API

    /// 根据输入前缀预测候选词
    ///
    /// 使用子序列匹配算法找出所有包含输入字母且顺序一致的单词，
    /// 然后按频率降序、长度升序排序，返回前 8 个。
    ///
    /// 算法示例：
    /// ```
    ///  输入 "pls" → "please"(3→5→5 匹配 p→l→s)
    ///            → "plans"(匹配 p→l→n→s)
    ///            → "plus"(匹配 p→l→u→s)
    /// ```
    ///
    /// - Parameter prefix: 用户输入的字母（如 "pls"），大小写不敏感
    /// - Returns: 匹配的候选词数组，最多 8 个
    func predict(prefix: String) -> [String] {
        let lower = prefix.lowercased()
        guard !lower.isEmpty else { return [] }

        // 子序列过滤
        var results = words.filter { isSubsequence(lower, in: $0.lowercased()) }

        // 排序：频率高的靠前，频率相同则短的靠前
        results.sort { a, b in
            let fa = frequencies[a.lowercased()] ?? 0
            let fb = frequencies[b.lowercased()] ?? 0
            if fa != fb { return fa > fb }
            return a.count < b.count
        }

        return Array(results.prefix(8))
    }

    /// 记录用户选中了一个词（增加其频率计数）
    /// - Parameter word: 用户选中的单词
    func recordSelection(_ word: String) {
        let key = word.lowercased()
        frequencies[key, default: 0] += 1
    }

    /// 将频率数据持久化到磁盘
    ///
    /// 以 JSON 格式写入 `~/.fime_frequencies.json`，下次启动时自动加载。
    func saveFrequencies() {
        guard let data = try? JSONEncoder().encode(frequencies) else { return }
        try? data.write(to: frequencyURL, options: .atomic)
    }

    // MARK: - 私有方法

    /// 加载单词列表
    ///
    /// 优先从 Bundle 内的 `words.txt` 资源文件加载，
    /// 若不存在则回退到系统词典 `/usr/share/dict/words`。
    private func loadWordList() {
        // 1) 优先使用 bundled 资源
        if let bundled = Bundle.main.path(forResource: "words", ofType: "txt"),
           let content = try? String(contentsOfFile: bundled, encoding: .utf8) {
            parseWords(from: content)
            return
        }

        // 2) 回退到系统词典
        let systemPath = "/usr/share/dict/words"
        guard let content = try? String(contentsOfFile: systemPath, encoding: .utf8) else {
            NSLog("[FIME] Could not load word list from any source")
            return
        }
        parseWords(from: content)
    }

    /// 解析单词列表文本
    ///
    /// 按换行分割，去除空白，过滤掉非字母内容。
    /// 取前 `maxWords` 个单词，如果数量不够则尝试从全 ASCII 字母词中补充。
    ///
    /// - Parameter content: 原始单词列表文本
    private func parseWords(from content: String) {
        let all = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }

        // 取前 maxWords 个短词（短的通常更常用）
        words = Array(all.prefix(maxWords))

        // 如果数量不够，从纯 ASCII 字母词中补充
        if words.count < maxWords / 2 {
            let extended = all.filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }
            words = Array(extended.prefix(maxWords))
        }

        NSLog("[FIME] Loaded \(words.count) words")
    }

    /// 从磁盘加载历史频率数据
    ///
    /// 读取 `~/.fime_frequencies.json`，若文件不存在或格式错误则静默忽略。
    private func loadFrequencies() {
        guard let data = try? Data(contentsOf: frequencyURL),
              let freqs = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }
        frequencies = freqs
        NSLog("[FIME] Loaded \(frequencies.count) frequency entries")
    }

    /// 子序列匹配算法
    ///
    /// 检查 `pattern` 是否按顺序出现在 `word` 中。
    /// 例如 "pls" 是 "please"、"plans"、"plus" 的子序列，
    /// 但不是 "slip" 的子序列（因为 p 在 s 之后出现）。
    ///
    /// 算法：双指针迭代，一个遍历 pattern，一个遍历 word，
    /// 当匹配到一个字符时 pattern 指针前进，直到所有 pattern 字符都匹配到。
    ///
    /// - Parameters:
    ///   - pattern: 要匹配的模式（小写）
    ///   - word: 要检查的单词（小写）
    /// - Returns: 如果 pattern 是 word 的子序列则返回 true
    private func isSubsequence(_ pattern: String, in word: String) -> Bool {
        var it = pattern.makeIterator()
        guard var current = it.next() else { return false }

        for wChar in word {
            if wChar == current {
                if let next = it.next() {
                    current = next
                } else {
                    return true // 所有 pattern 字符都已匹配
                }
            }
        }
        return false
    }
}
