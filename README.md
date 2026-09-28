<div align="center">

# 🛰️ Nexus

### 跑在你自己设备上的 AI 对话客户端

API Key 自己填 · 请求直连你选的模型服务商 · 聊天记录与设置只存本机，出网只去你配置的端点和本仓库的公开文件

<br />

![Android](https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat-square&logo=dart&logoColor=white)
![Release](https://img.shields.io/github/v/release/songchuangchang/Nexus?style=flat-square&logo=github)
![Beta](https://img.shields.io/badge/Status-Beta-D97706?style=flat-square)
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
- [⚠️ 免责声明](#-免责声明)
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
- 插件市场、MCP 连接器、Skills；服务商模板 / 内置提示词 / 连接器目录可由远程数据包更新
  （版本闸门 + 结构校验；校验和是可选字段，这几份文件暂未提供。目前只有连接器目录那份真在闸内可用，
  另两份的远程版本仍低于内置基线，读到了也会被闸判旧而拒绝——这是已知项）
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
| 安卓模拟器 | `x86_64` |

当前所有安装包均为 **Beta 测试版**，功能与稳定性仍在打磨，遇到问题欢迎反馈。

覆盖安装即可，**不需要先卸载**——卸载会连聊天记录和存进系统保险库的 API Key 一起清掉。

若系统提示「应用未安装」或签名不一致，通常是旧包为 debug 签名（例如自己从源码构建过）：
正式签名的包之间覆盖升级不会有此提示。请先在 App 内备份数据，再卸载重装，不要直接卸载。

App 内「设置 → 关于」会检查更新，读的就是本仓库的 latest release；该页显示完整版本号，
系统应用信息里只显示 `1.7.113` 这种不带构建号的短版本号，属正常现象。

## 🛠️ 从源码构建

需要 Flutter 3.47+（Dart 3.13+）与 JDK 17：

```bash
flutter pub get
flutter analyze
flutter build apk --release --flavor direct --split-per-abi
```

`--flavor direct` 是"从 GitHub Releases 自更新"这一档，另有 `store` 档面向应用商店渠道，
两档目前同源。本仓库是发布镜像，只放代码快照，**测试用例不在这里**（构建不依赖它们）。

一处实话：`android/gradlew`、`gradlew.bat` 与 `android/gradle/wrapper/gradle-wrapper.jar`
被 `android/.gitignore` 忽略，所以没有进这个镜像；直接调 Gradle 的构建路径要先在自己的
Android 目录里生成 wrapper，走 `flutter build` 这一路则不必。

release 包恒开 R8 混淆与资源压缩；签名读取 `android/key.properties`，
该文件缺失时 Gradle 会明确告警并退回 debug 签名，这种包不能覆盖正式版，也不要分发。

## 🔒 隐私与数据

- 聊天记录、设置、API Key 全部存在设备上：Key 优先写进 Android 系统保险库（Keystore）；
  个别机型写不进去时会退回本地明文存储并如实标注——**宁可降级也不让你的 Key 凭空消失**
- 出网只有两类去向：你自己在设置里配的模型/搜索端点，以及本仓库的公开文件
  （更新检查、安全扫描规则与数据包；读这些文件时会经过镜像加速地址）
- 更新检查与数据包同步不携带任何设备标识

## 🛡️ 权限

清单以 `android/app/src/main/AndroidManifest.xml` 为准（现读 18 项），逐条对应它能做的事：

- **通知（含 `POST_PROMOTED_NOTIFICATIONS`）/ 前台服务（`FOREGROUND_SERVICE`、`_DATA_SYNC`、`_SPECIAL_USE`）**：
  可选，默认关；关着时一个权限都不问，打开后长任务在离开 App 时仍可见
- **生物识别（`USE_BIOMETRIC` / `USE_FINGERPRINT`）**：可选，用于打开 App 与查看已保存的 Key
- **相机与媒体（`CAMERA`、`READ_MEDIA_IMAGES/VIDEO/AUDIO`、`READ/WRITE_EXTERNAL_STORAGE`）**：
  仅在你主动附图、附文件、导出或预览本地文件时使用
- **位置（`ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`）**：只有你在对话里让助手用到定位时才会读
- **安装应用（`REQUEST_INSTALL_PACKAGES`）**：只服务于 App 内那一跳自更新，不会后台静默安装
- 本 App **没有**录音权限（`RECORD_AUDIO` 声明数为 0），也就没有听写/语音输入

## ⚠️ 免责声明

- AI 生成内容仅供参考，可能存在错误，重要决定请自行核实
- API Key 由你填写、请求费用由你与模型服务商结算；因配置错误或模型自主调用工具
  产生的费用，本软件不承担责任
- 本软件按"原样"提供，不含任何明示或暗示的担保，完整条款见 [LICENSE](LICENSE)

## 📄 版本与许可

- 版本号形如 `1.7.113+170`，`+` 后为构建号
- 变更记录见 [CHANGELOG.md](CHANGELOG.md)；历史版本及发布说明见 [Releases](https://github.com/songchuangchang/Nexus/releases)
- 本项目许可见 [LICENSE](LICENSE)
- 第三方组件许可清单见 [docs/THIRD_PARTY_LICENSES.md](docs/THIRD_PARTY_LICENSES.md)，App 内「设置 → 关于」也指向该文件

---

<div align="center">

⭐ 如果这个项目对你有用，欢迎点个 Star

[![Star History](https://star-history.com/svg?repos=songchuangchang/Nexus&type=Date)](https://star-history.com/#songchuangchang/Nexus&Date)

</div>
