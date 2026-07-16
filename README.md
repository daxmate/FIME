# FIME — macOS English Word Prediction Input Method

A macOS input method that provides English word prediction as you type, using
**subsequence matching** (e.g. typing "pls" matches "please", "plans", "plaster").

## Features

- **Subsequence matching**: type any subset of letters in order to find words
- **Dynamic frequency sorting**: words you select more often rise to the top
- **Candidate window**: shows up to 8 candidates via `IMKCandidates`
- **3000-word dictionary** from `/usr/share/dict/words`

## Keybindings

| Key | Action |
|-----|--------|
| `a-z` | Build up input buffer; candidates update live |
| `Space` | Commit top candidate + space |
| `Return` / `Tab` | Commit top candidate |
| `1` … `8` | Commit n-th candidate |
| `Escape` | Clear buffer, hide candidates |

## Build & Install

```bash
# Build only (creates .build/FIME.app)
./build.sh

# Build + install to /Library/Input Methods/
sudo ./build.sh install
```

After installing, **log out & back in**, then enable in:
**System Settings → Keyboard → Input Sources → Add "FIME"**

## Project Structure

```
FIME/
├── Sources/
│   ├── main.swift                        # NSApplication + AppDelegate + IMKServer
│   ├── FIMEController.swift       # IMKInputController subclass
│   ├── WordEngine.swift                  # Matching & sorting service
│   └── WordDatabase.swift                # Dictionary + frequency manager
├── Resources/
│   └── words.txt                         # 3000 English words
├── Info.plist                            # Bundle metadata + IMK config
├── FIME.entitlements              # Sandbox entitlements
├── Package.swift                         # SPM project (Xcode-compatible)
└── build.sh                              # Compile + bundle script
```

## Technical Details

- **Language**: Swift 5.9+ (no Objective-C)
- **Framework**: InputMethodKit, AppKit, Foundation
- **macOS target**: 14.0+ (Sonoma / Tahoe compatible)
- **Bundle ID**: `com.inputmethod.FIME`
- **Sandbox**: Enabled with Mach-registration exception
- **Frequency data**: stored at `~/.fime_frequencies.json`
