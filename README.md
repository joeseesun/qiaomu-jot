<div align="center">

<img src="docs/assets/icon.png" width="96" alt="乔木闪记 Jot icon">

# 乔木闪记 · Jot

**中文** | [English](#english)

按一下快捷键，把想法、选中的文字、截图和文件，收进 Obsidian 今日日记或任意 Markdown 文件夹。<br>
Press a shortcut to capture thoughts, selections, screenshots and files into your Obsidian daily note — or any Markdown folder.

[![下载 Download](https://img.shields.io/github/v/release/joeseesun/qiaomu-jot?label=%E4%B8%8B%E8%BD%BD%20Download&color=111)](https://github.com/joeseesun/qiaomu-jot/releases/latest/download/Jot.dmg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111)
![Apple notarized](https://img.shields.io/badge/Apple-notarized-111)
[![License MIT](https://img.shields.io/badge/license-MIT-111)](LICENSE)

<img src="docs/assets/hero.png" alt="乔木闪记：在网页上按 ⌘⇧K 收录选中内容，带上来源" width="820">

</div>

**已验证：** `Jot --selftest` 106 项检查全部通过（编辑、记录格式、写入、剪贴板、搜索、场景、本机 OCR）；安装包经 Apple 公证（`spctl`：Notarized Developer ID）；Apple 芯片与 Intel 通用二进制。

## 这是什么

记笔记最难的不是写，而是**打开笔记**。看到一句好话、截了一张图、冒出一个念头，等你切到 Obsidian、找到今天的日记、再粘贴回来，那个念头已经凉了。

乔木闪记是一个常驻菜单栏的小工具，两个快捷键解决这件事：

| 快捷键 | 做什么 |
|---|---|
| **⌘⇧J** 随手记 | 在任何地方弹出一个输入框，写字、粘贴截图、拖入图片视频，⌘↩ 存进今日日记 |
| **⌘⇧K** 一键收录 | 不弹窗。选中的文字、网页、PDF、代码、Finder 里的文件，直接存进去；没选中就存剪贴板或刚截的屏 |

快捷键可以在设置里改成任何组合。还可以加最多 6 个**场景**：比如 ⌃⌥1「灵感」、⌃⌥2「读书摘录」，按一下就记到对应的笔记或文件夹。

## 核心能力

| 能力 | 你得到什么 |
|---|---|
| 内容原样保存 | 不自动加列表点、引用符号；复制的是什么就存什么 |
| 自动带来源 | 网页存成 `[标题](链接)`，PDF 带文件名和页码，电子书带书名和作者，代码带文件名和语言 |
| 剪贴板与截图 | 没选中内容时，收录剪贴板里的文字、图片、视频、文件，或刚截的屏；同一份只收一次。不想让剪贴板进日记，可在「设置 → 记录」关掉「空选时收录剪贴板」 |
| 网页记忆 | 存的每个网页是一条一级标题，附上页面描述和无广告的头部截图，左侧大纲直接可见；同一网页再按时，补充想法、选中的文字（转为二级小节）和文件都归到该页章节下，而不是散落各处 |
| 截图文字识别 | 本机识别中英文，写进图片下方默认折叠的块，日后能搜到 |
| Markdown 实时渲染 | 编辑时就看到粗体、标题、列表、代码；⌘B ⌘I ⌘K 等快捷键和格式栏 |
| 场景 | 给常用去处配快捷键：选预设、按快捷键、选笔记或文件夹，三步就能用 |
| 全库搜索 | ⌘P 搜任意笔记和文件夹：模糊匹配、拼音和首字母（`zssn` → 置身事内）、别名、笔记正文 |
| 存到哪都行 | 默认今日日记，也可追加到任意笔记或在文件夹里新建笔记；记住最近用过的位置 |
| 不依赖 Obsidian | 选普通文件夹就用标准 Markdown 链接，Typora、VS Code、iA Writer 都能打开 |
| 随时撤销 | 提示条和菜单栏都能撤销上一条，或给它补一句想法；提示条上点「打开」直接看这条笔记（Obsidian 仓库用 Obsidian，普通文件夹用默认 Markdown 应用） |
| 自动更新 | 有新版时在菜单栏旁轻提示，一键更新（Sparkle，签名校验） |
| 隐私 | 全部在本机完成；密码框和 1Password 等密码管理器的内容不收录 |

## 写进笔记的样子

默认样式（可在设置里换成列表、引用块、Callout 或自定义模板）：

```markdown
地方政府不只是“守夜人”，而是深度参与经济发展的“运动员”。
> 14:32 · [置身事内 - 读书笔记](https://example.com/book)

![[截屏 2026-11-04 下午2.32.png]]
> [!note]- 图中文字
> 好的工具让记录这件事消失
```

## 快速开始

1. 下载 [**Jot.dmg**](https://github.com/joeseesun/qiaomu-jot/releases/latest/download/Jot.dmg)，打开后把「乔木闪记」拖进「应用程序」。
2. 打开它。菜单栏出现图标，设置窗口会自动弹出：
   - 选择保存位置：已装 Obsidian 会自动选中最近的仓库；没装就用 `~/文稿/乔木闪记`。
   - 点「开启辅助功能…」授权。收录其他 App 里选中的内容需要这个权限。
3. 在任何地方按 **⌘⇧J** 写一句话，按 **⌘↩** 保存。

设置「通用」页顶部的「开始使用」清单会带你走完这三步。之后有新版本会自动提示。

<details>
<summary>从源码构建</summary>

需要 macOS 13+ 与 Xcode 16+。

```bash
git clone https://github.com/joeseesun/qiaomu-jot.git
cd qiaomu-jot
./build.sh                                        # 生成 build/Jot.app
"build/Jot.app/Contents/MacOS/Jot" --selftest     # 自测，最后一行应为 ALL PASS
open build/Jot.app
```

没有 Developer ID 证书时，`build.sh` 会用临时签名，这时每次重新构建都要重新授权辅助功能。

</details>

## 产品巡游

| | |
|---|---|
| <img src="docs/assets/panel-dark.png" alt="深色模式与格式栏"> | <img src="docs/assets/picker.png" alt="选择保存位置"> |
| **Markdown 实时渲染**：⌘/ 展开格式栏，列表回车自动续写，`#` 补全标签 | **⌘P 选位置**：今日日记、最近用过的笔记与文件夹、全库搜索 |
| <img src="docs/assets/record.png" alt="记录格式设置"> | <img src="docs/assets/about.png" alt="关于"> |
| **记录格式**：样式、时间格式、来源开关，实时预览写出来的样子 | **关于**：版本、反馈、使用说明 |

## 使用方式

| 操作 | 快捷键 |
|---|---|
| 打开输入框 / 收录选中内容 | ⌘⇧J / ⌘⇧K（可自定义） |
| 保存 / 关闭（保留草稿） | ⌘↩ / Esc |
| 选择保存位置（搜索全库） | ⌘P |
| 场景 | 自定义，默认 ⌃⌥1…6 |
| 格式栏 / 添加附件 | ⌘/ / ⌘O |
| 粗体 · 斜体 · 链接 · 行内代码 | ⌘B · ⌘I · ⌘K · ⌘E |
| 标题 · 待办 · 列表 · 引用 | ⌘1/2/3 · ⌘L · ⌘⇧8 · ⌘' |
| 补全标签 | 输入 `#` 后按 Tab |
| 设置 | ⌘, |

还可以把文件拖到菜单栏图标上收录，或在 ⌘⇧K 提示条显示时再按一次，给刚才那条补一句想法。

## 不用 Obsidian 也能用

保存位置是 Obsidian 仓库（有 `.obsidian` 文件夹）还是普通文件夹，会自动识别：

| | Obsidian 仓库 | 普通文件夹 |
|---|---|---|
| 日记位置 | 沿用「日记」插件的文件夹、文件名和模板 | `日记/2026-11-04.md`，可在设置里改 |
| 附件 | 沿用 Obsidian 的附件设置，`![[图.png]]` | `附件/`，标准 `![](../附件/图.png)` |
| 截图文字 | 可折叠 Callout | `<details>` 折叠块 |
| 打开笔记 | 在 Obsidian 中打开 | 用默认 Markdown 编辑器打开 |

## 限制、隐私与边界

- **只支持 macOS 13 及以上**。在 macOS 27 的 Apple 芯片 Mac 上开发和测试；Intel 版是通用二进制，未在 Intel 实机上验证。
- **权限**：
  - 「辅助功能」用来读取选中的文字。
  - 「自动化」只在读取浏览器网页标题、邮件链接时请求一次。
  - 「桌面文件夹」只在收录刚截的屏时请求。
- **剪贴板**：需要带格式收录网页、邮件或 Finder 内容时，会模拟一次 ⌘C，读完立即恢复你原来的剪贴板，并标记为临时内容，避免进入剪贴板管理工具的历史。
- **网络**：只有「粘贴链接自动换成网页标题」会访问那个网页，可以在设置里关闭。不上传、不统计任何数据。
- **不做什么**：不同步，不管理笔记，不替代 Obsidian 或你的 Markdown 编辑器，只负责把东西快速放进去。

## 项目结构

```text
Sources/Jot/          macOS Swift 源码（SwiftUI + AppKit）
windows/QiaomuJot/    Windows 原生源码（.NET 9 + WPF + Windows.Media.Ocr）
  App.xaml.cs           单例检测、托盘常驻、启动与自检入口
  Services/             全局键盘钩子、剪贴板抓取与恢复、离线OCR、日记读写与撤销
  UI/                   随手记浮动窗口、Toast提示、设置窗口与托盘菜单
Resources/            图标（Icon Composer）、字体、音效、品牌图标
build.sh · release.sh  构建；签名、DMG、公证
```

## 致谢

[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Sparkle](https://sparkle-project.org) · [Geist](https://github.com/vercel/geist-font) · [Lucide](https://lucide.dev) · [Simple Icons](https://simpleicons.org) · [Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds)。许可详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

欢迎提 [issue](https://github.com/joeseesun/qiaomu-jot/issues) 和 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 关于向阳乔木

乔向阳，网名向阳乔木，前字节/TikTok 商业化 AI 产品经理、连续创业者，把 AI 前沿变化转译成产品判断和可执行的工作流。

[qiaomu.ai](https://qiaomu.ai) · [博客](https://blog.qiaomu.ai) · [乔木推荐](https://tuijian.qiaomu.ai) · [X @vista8](https://x.com/vista8) · [GitHub @joeseesun](https://github.com/joeseesun)

| 关注公众号「向阳乔木推荐看」 | 请我喝杯咖啡 |
|:---:|:---:|
| <img src="docs/assets/wechat-qr.jpg" width="160" alt="公众号二维码"> | <img src="docs/assets/reward-qr.png" width="160" alt="打赏二维码"> |

MIT © 2026 向阳乔木

---

<a name="english"></a>

# English

**Jot** (乔木闪记) is a menu bar app for macOS. It captures a thought, a selection, a screenshot or a file into your **Obsidian daily note**, or into any plain Markdown folder, with one shortcut.

- **⌘⇧J — Quick note.** A floating editor with live Markdown rendering. Paste screenshots, drop images or videos, press ⌘↩.
- **⌘⇧K — Capture selection.** Saves whatever is selected in the front app, without a window: web text (converted to Markdown, with page title and link), PDF text (line breaks repaired, with page number), Apple Books and Kindle quotes (citation parsed), code (fenced, language detected), or Finder files. With nothing selected it saves the clipboard (text, images, video, files) or the screenshot you just took. Each one is saved only once. The clipboard part can be turned off in Settings → Record.
- **Page memory.** Every saved page becomes a level-1 heading with its site description and an ad-blocked screenshot of the page top — visible in the outline. Saving the same page again files your thoughts, selected text (as a level-2 section with the full quote) and files under that page instead of duplicating the link. The description and screenshot can be turned off in Settings → Record.
- **Verbatim by default.** No bullets or quote markers are added to your content. Time and source go on a separate quote line, and both can be turned off. Presets: plain, time-first, list, quote, callout, or your own template.
- **On-device OCR.** Text in screenshots is written to a folded callout under the image, so you can search for it later.
- **Scenes.** Up to six named shortcuts (e.g. ⌃⌥1 Ideas, ⌃⌥2 Reading notes), each aimed at a note or folder. Pick a preset and it works immediately.
- **Whole-vault search.** ⌘P finds any note or folder: fuzzy matching, pinyin and initials, aliases, and note contents (via Spotlight).
- **Any destination.** Today's daily note by default; append to any note, or create a new note in any folder, with recent places listed first.
- **Auto-update.** Sparkle, with signed updates and a quiet reminder instead of a pop-up.
- **Works without Obsidian.** A plain folder gets `日记/YYYY-MM-DD.md`, an `附件/` attachments folder and standard Markdown image links.
- **Undo** from the toast or the menu bar, or add a follow-up thought to the entry you just saved. **Open** in the toast shows the note: in Obsidian for a vault, otherwise in your default Markdown app.

### Install

Download [**Jot.dmg**](https://github.com/joeseesun/qiaomu-jot/releases/latest/download/Jot.dmg). It is notarized by Apple and runs natively on Apple silicon and Intel. Drag the app to Applications and open it. Then:

1. Choose where to save (your Obsidian vault is detected automatically).
2. Grant **Accessibility**, which is needed to read selections in other apps.
3. Press **⌘⇧J** anywhere.

Build from source with `./build.sh` (macOS 13+, Xcode 16+). `build/Jot.app/Contents/MacOS/Jot --selftest` runs 106 checks.

### Privacy & limits

- **Local only.** Nothing is uploaded and nothing is tracked. The only network request fetches a page title when you paste a bare link, and you can turn that off.
- **Clipboard.** Rich selections are copied with a synthetic ⌘C; your clipboard is restored right after and marked as transient for clipboard managers.
- **Excluded content.** Password fields and password managers are never captured.
- **Tested on.** Developed and tested on macOS 27 (Apple silicon). The Intel slice is built but not tested on Intel hardware. The UI is in Chinese.

MIT © 2026 向阳乔木 (Qiaomu) · [X @vista8](https://x.com/vista8) · Third-party licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
