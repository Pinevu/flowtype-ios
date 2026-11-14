# FlowType — iOS AI 语音 + 全拼/英文输入法

参照 Typeless iOS 核心体验打造的开源可自定义 AI 语音输入法工程，包含 **主 App（麦克风采集 + PiP 画中画保活 + AI 调度 + 个人词典 + 效率热力图）** 与 **键盘扩展（语音上屏 + 语音改写/翻译 + 完整自定义中文全拼 & 英文手打键盘）**，并内置 **GitHub Actions 云端自动编译打包工作流**。

---

## 核心功能

- **AI 语音听写与智能润色**：自动去除语气词、识别口述中途改口自纠、自动分段与标点。
- **Speak to Edit & Help me write**：读取光标选中文本或上下文，语音下达改写指令或直接生成邮件/回复。
- **实时多语言翻译**：预设多个目标语言，口述母语后按目标语言地道表达输出。
- **PiP 画中画免切 App 保活**：主 App 通过 `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` 在后台待命，空闲时关闭麦克风省电护隐私，切回微信/备忘录等任意 App 后点键盘即可直接录音上屏（支持实心/空心麦状态指示与深度链接自动唤醒）。
- **完全自定义 AI 接口**：
  - **ASR 语音识别**：支持 OpenAI Whisper 兼容接口（OpenAI / Groq / 硅基流动 SenseVoice 等）、Google Gemini 音频直出，以及免 Key 的 Apple 系统语音识别。
  - **LLM 文本整理**：支持 OpenAI 兼容接口（OpenAI / DeepSeek / Groq / 硅基流动 / 本地 Ollama 等）、Google Gemini、Anthropic Claude，及纯原文直出模式；可自定义 4 套 Prompt。
- **个人词典 & 纠错自学习**：支持搜索、添加（含拼音提示）、多选批量删除，在手打修正语音输入后自动学入个人词典并注入后续识别热词。
- **完整自定义英文 + 中文全拼手打键盘**：
  - 支持滑动切面板（Swipe-to-type）、全拼切分、简拼（`nh` -> `你好`、`srf` -> `输入法`）、整句 Viterbi 解码（`woxiangchifan` -> `我想吃饭`）、逐步选词、模糊音、个人词频自学习、候选词展开抽屉。
  - 支持英文 QWERTY + `UITextChecker` / `UILexicon` / 词频联想 + 大小写/CapsLock + 空格滑动移动光标（Trackpad）+ 长按连续退格 + 中英文标点符号页。

---

## GitHub Actions 云端自动编译与证书签名

工作流位于 `.github/workflows/build-ipa.yml`，支持 **未签名 IPA** 和 **正式证书签名 IPA** 两种产物：

### 方式一：零配置打包未签名 IPA（推代码即出包）

直接将本仓库推送到 GitHub `main` 分支：
1. GitHub Actions 会自动在 `macos-latest` 上安装 `xcodegen`、生成工程、运行 `FlowTypeTests` 单元测试。
2. 未配置证书 Secrets 时，自动输出 `FlowType-unsigned-ipa` Artifact（可用于 **TrollStore 巨魔**、**轻松签 / ESign**、**AltStore / Sideloadly** 或 `zsign` 本地重签名）。

### 方式二：配置 Apple 证书 Secrets 云端直出签名 IPA

在 GitHub 仓库 `Settings -> Secrets and variables -> Actions` 添加以下 Secrets（注意键盘扩展必须拥有独立 Bundle ID 和匹配的描述文件，且两者需开通**同一个 App Group**）：

| Secret 名称 | 说明 |
| :--- | :--- |
| `IOS_P12_BASE64` | 导出 `.p12` 证书文件的 Base64 字符串（如 `base64 -i cert.p12 \| pbcopy`） |
| `IOS_P12_PASSWORD` | `.p12` 证书密码 |
| `IOS_APP_PROVISION_BASE64` | 主 App（如 `com.yourname.flowtype.app`）的 `.mobileprovision` Base64 |
| `IOS_EXT_PROVISION_BASE64` | 键盘扩展（如 `com.yourname.flowtype.app.keyboard`）的 `.mobileprovision` Base64 |
| `APPLE_TEAM_ID` | *可选*，通常会自动从描述文件中解析 |

> 构建脚本 `scripts/ci_configure_signing.py` 会自动从两个 `.mobileprovision` 中读取真实的 `Team ID`、`Bundle ID`、`App Group ID` 和 `UUID` 并注入 `project.yml`，无需手动修改源码。

在 GitHub Actions 页面点击 **Run workflow** 即可选择 `signing_mode`（`auto` / `unsigned` / `signed`）和 `export_method`（`ad-hoc` / `development` / `enterprise` / `app-store-connect`）。

---

## iPhone 真机使用步骤

1. 安装打包好的 `.ipa` 后，先打开一次 **FlowType 主程序**，在「设置」中填入你的 ASR / LLM API Key（或先选 Apple 系统语音识别 + 任意 LLM）。
2. 前往 iPhone **系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘**，选择 **FlowType 语音键盘**。
3. 点进 **FlowType 语音键盘** 并打开 **「允许完全访问」**（用于共享 App Group 语音状态、词典与配置）。
4. 回到 **FlowType 主程序 → 主页**，点击 **「启动画中画待命」**，再切到微信 / 备忘录 / 邮件等任意输入场景即可体验免切 App 语音输入与全拼/英文键盘。

---

## 本地更新词库（可选）

仓库已附带预编译好的 `FlowTypeKeyboard/Resources/lexicon.sqlite`（约 7.3 MB，包含 2.7 万单字读音、8 万中文词组、2.5 万英文高频词）。如需重新构建：

```bash
python3 scripts/build_lexicon.py
```
