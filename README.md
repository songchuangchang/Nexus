<div align="center">

# 🛰️ Nexus

### 跑在你自己设备上的 AI 对话客户端

API Key 自己填 · 请求直连你选的模型服务商 · 聊天记录与设置只存本机，不经过任何第三方服务器

<br />

![Android](https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-0078D4?style=flat-square&logo=windows&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat-square&logo=dart&logoColor=white)
![Release](https://img.shields.io/github/v/release/songchuangchang/Nexus?style=flat-square&logo=github)
![License](https://img.shields.io/badge/License-BSD_3--Clause-398AC7?style=flat-square)
![Privacy](https://img.shields.io/badge/Privacy-Local_First-34D399?style=flat-square&logo=shield&logoColor=white)

<br />

**[⬇️ 立即下载](https://github.com/songchuangchang/Nexus/releases/latest)** ｜ [从源码构建](#-从源码构建) ｜ [隐私说明](#-隐私与数据)

</div>

---

<details>
<summary><kbd>目录</kbd></summary>

- [📱 截图](#-截图)
- [✨ 主要能力](#-主要能力)
- [⬇️ 安装](#-安装)
- [🛠️ 从源码构建](#-从源码构建)
- [🔒 隐私与数据](#-隐私与数据)
- [🛡️ 权限](#-权限)
- [📄 版本与许可](#-版本与许可)

</details>

## 📱 截图

<div align="center">

<em>📸 真机截图准备中（对话页 / 反问轮 / 灵动岛 / 设置 / 宽屏平板布局）</em>

<!-- 截图就绪后：把图片放进 docs/screenshots/，再用下面的写法替换本提示
<img src="docs/screenshots/chat.png" width="240" />
<img src="docs/screenshots/live-update.png" width="240" />
<img src="docs/screenshots/settings.png" width="240" />
-->

</div>

## ✨ 主要能力

### 💬 对话与模型

- 自定义 API 配置：多家服务商模板，也支持任意 OpenAI 兼容端点与本地模型
  （Ollama、LM Studio 等，手机填电脑的局域网地址即可）
- 自主思考循环（ReAct）：模型自己决定要不要调工具、调几个、什么时候收口，
  每一轮的思考与工具调用都留在可展开的时间线里
- 联网搜索：可设为自动或按需，带轮数上限
- 反问：模型信息不够时会停下来问你一句，而不是猜一个答案
- 生成中断后可以从断点续写，也可以整轮重新发起；「停止并撤回」会把这一轮收回去
- 上下文用量实时可见，输出预留与请求参数按同一个判断走

### 🔔 长任务与通知

- Android 16 的 Live Updates（`ProgressStyle` 分段进度），以及 OPPO / vivo 厂商的
  常驻通知形态；下载、备份、深度研究、生成视频这类没有字节进度的任务也能看出走到哪一步
- 「愿意后台化」总闸默认关：关时不要权限、不投影灵动岛；打开后离开 App 仍保持连接
- 一轮结束时岛上的状态词分四档：已完成 / 失败 + 原因 / 等你回答 / 提前结束两个都不写

### 🗂️ 数据与扩展

- 跨会话记忆与项目分组；知识库（RAG）与提示词模板
- 插件市场、MCP 连接器、Skills；服务商模板 / 内置提示词 / 连接器目录支持热更新
  （带版本闸门与校验和，取不到就继续用 APK 内置的那份）
- 文件管理、会话归档、备份到网盘（保留份数可关）
- 图片文字识别（本机 OCR，不上传）

### 🎨 界面

- 中英文双语；深色主题
- 手机 / 平板 / 折叠屏分档：内容列宽度只有一道闸，气泡按内容列而不是整屏宽算
- 输入框随键盘伸缩由引擎的逐帧事实驱动，展开和收回用同一条时钟

## ⬇️ 安装

到 [Releases](https://github.com/songchuangchang/Nexus/releases/latest) 下载对应架构：

| 你的设备 | 装这个 |
|---|---|
| 近几年的手机、平板（绝大多数） | `arm64-v8a` |
| 很老的 32 位机型 | `armeabi-v7a` |
| 安卓模拟器 / Windows 11 on ARM | `x86_64` |

覆盖安装即可，**不需要先卸载**——卸载会连聊天记录和存进系统保险库的 API Key 一起清掉。

App 内「设置 → 关于」会检查更新，读的就是本仓库的 latest release。

## 🛠️ 从源码构建

需要 Flutter 3.47+（Dart 3.13+）：

```bash
flutter pub get
flutter analyze
flutter test -j 2
flutter build apk --release --flavor direct --split-per-abi
```

`--flavor direct` 是"从 GitHub Releases 自更新"这一档；测试并发固定 `-j 2`，
默认并发会抢 pub 锁导致假失败。

## 🔒 隐私与数据

- 聊天记录、设置、API Key 全部存在设备上：Key 走 Android Keystore，
  不是明文放在数据库里
- 除了你自己在设置里配的模型/搜索端点，App 不向任何服务器发起请求
- 更新检查与数据包同步读取本仓库的公开文件，不携带任何设备标识

## 🛡️ 权限

- **通知 / 前台服务**：可选，请在通用设置修改
- **生物识别**：可选，用于打开 App、查看已保存的 Key
- **相机 / 相册 / 麦克风**：仅在主动附图、附文件或听写时使用

## 📄 版本与许可

版本号形如 `1.7.113+170`，`+` 后为构建号。历史版本及说明见 Releases 页。
本项目许可见 `LICENSE`；第三方组件许可清单见
[docs/THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md)，
App 内「设置 → 关于」也指向该文件。

---

<div align="center">

⭐ 如果这个项目对你有用，欢迎点个 Star

[![Star History](https://star-history.com/svg?repos=songchuangchang/Nexus&type=Date)](https://star-history.com/#songchuangchang/Nexus&Date)

</div>
