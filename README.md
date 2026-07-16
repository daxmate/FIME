# FIME — macOS 英文预测输入法

> **Fi**zzy I**ME** — 模糊匹配英文输入法

FIME 是一款 macOS 原生输入法（InputMethodKit），当你输入字母时，它会根据 **子序列匹配** 算法实时预测你想要的单词。

例如输入 `pls`，候选词会显示 `please`、`plans`、`plaster` 等包含 p→l→s 子序列的单词。

## 截图

_（暂无，敬请期待）_

## 特性

- **子序列匹配** — 输入任意字母子集，按序匹配所有可能的单词
- **动态频率排序** — 你选过的词频率会自动上升，越用越准
- **候选窗** — 最多 8 个候选，`IMKCandidates` 原生渲染
- **3000+ 词库** — 基于系统 `/usr/share/dict/words`，可自定义扩充

## 快捷键

| 按键 | 行为 |
|------|------|
| `a`–`z` | 输入字母，候选实时更新 |
| `Space` | 选中第一个候选 + 空格 |
| `Return` / `Tab` | 选中第一个候选 |
| `1`–`8` | 选中第 n 个候选 |
| `Escape` | 清空输入、隐藏候选窗 |

## 如何使用

### 安装

```bash
cd ~/codes/FIME
bash build.sh install
```

然后**登出再登入**，进入 **系统设置 → 键盘 → 输入法**，添加 FIME 即可。

切换后 FIME 会自动启动，无需手动操作。

### 开发

```bash
bash build.sh           # 仅编译到 .build/
bash build.sh clean     # 清理编译产物
```

## 项目结构

```
FIME/
├── Sources/
│   ├── main.swift                       # 入口：NSApplication + AppDelegate + IMKServer
│   ├── FIMEController.swift             # IMKInputController 子类（ObjC 兼容）
│   ├── WordEngine.swift                 # 子序列匹配 + 排序引擎
│   └── WordDatabase.swift               # 词库加载 + 用户频率持久化
├── Resources/
│   ├── words.txt                        # 3000+ 英文常用词
│   └── FIME.icns                        # 应用图标
├── Info.plist                           # 输入法注册信息
├── FIME.entitlements                    # 代码签名权限
├── Package.swift                        # SPM 配置（可选）
├── build.sh                             # 编译 + 签名 + 安装脚本
├── .gitignore
└── README.md
```

## 技术细节

- **语言**: Swift 5.9+（纯 Swift，利用 `@objc` 与 InputMethodKit 交互）
- **框架**: InputMethodKit · AppKit · Foundation
- **目标系统**: macOS 14.0+
- **Bundle ID**: `com.inputmethod.FIME`
- **签名**: ad-hoc（`codesign -s -`），无需苹果开发者账号
- **权限**: `com.apple.security.cs.disable-library-validation`
- **频率数据**: `~/.fime_frequencies.json`

### 构建方式

FIME 使用 `swiftc` 直接编译，不依赖 Xcode：

```bash
swiftc \
  -target arm64-apple-macos14.0 \
  -framework InputMethodKit -framework AppKit -framework Foundation \
  Sources/*.swift -o .build/FIME/Contents/MacOS/FIME
```

打包后用 `codesign` 签名，然后拷贝到 `/Library/Input Methods/`。

## 开发笔记（写给未来的自己）

如果你（大象）想从头学怎么写一个输入法，以下几点值得记住：

### macOS 输入法是如何启动的？

1. 输入法以 `.app` 包的形式安装在 `/Library/Input Methods/` 下
2. 登入时，系统服务 `imklaunchagent` 扫描该目录，读每个 app 的 `Info.plist` 注册
3. 当你在输入法菜单切换时，`imklaunchagent` 负责启动对应进程并建立 IPC 连接

### 最容易踩的坑

| 坑 | 表现 | 解决方法 |
|----|------|----------|
| `Info.plist` 权限是 600 | 输入法不出现 | `chmod 644 Info.plist` |
| 安装脚本调了 `lsregister` | 全系统输入法重复 | 只 `cp`，不碰系统注册 |
| Sandbox + ad-hoc | 进程崩溃 | entitlements 中去掉 Sandbox |
| `IMKServer` 传 `nil` | `activateServer` 不触发 | 传 `Bundle.main.bundleIdentifier` |
| 控制器类找不到 | `imklaunchagent` 拒绝启动 | 类加 `@objc` 标记 |

### 关键文件说明

- **`Info.plist`**: 输入法的身份证。`InputMethodConnectionName`, `InputMethodServerControllerClass`, `ComponentInputModeDict` 缺一不可
- **`FIMEController.swift`**: 核心控制器，继承 `IMKInputController`。重写 `inputText(_:client:)` 接收按键、`commitComposition(_:)` 提交文本
- **`WordEngine.swift`**: 预测算法的实现。子序列匹配 = 检查目标词是否包含输入的所有字母且顺序一致
- **`build.sh`**: 一键编译+打包+签名+安装

## 协议

MIT
