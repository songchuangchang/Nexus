# 第三方依赖与许可证清单

> 生成时间：2026-08-30 · v1.7.33

## 当前结论
- 当前项目包含本机 OCR 能力：`google_mlkit_text_recognition`（Flutter 插件）+ `com.google.mlkit:text-recognition-chinese`（Android 原生库），两者均为 Apache-2.0。
- 用途：当所选 API 配置关闭「视觉支持」时，图片附件在本机做文字识别，把识别出的文字注入上下文，不把图片发给模型。
- 本项目使用的第三方组件主要如下；其中 `archive` 与 `syncfusion_flutter_pdf` 有额外归属要求，见下文。

| 包 | 版本 | 许可证 |
|---|---|---|
| archive | 4.2.0 | MIT（另含上游派生组件，见下方归属说明） |
| args | 2.7.0 | BSD |
| async | 2.13.1 | BSD |
| boolean_selector | 2.1.2 | BSD |
| characters | 1.4.1 | BSD |
| clock | 1.1.2 | Apache-2.0 |
| code_assets | 1.2.1 | BSD |
| collection | 1.19.1 | BSD |
| convert | 3.1.2 | BSD |
| cross_file | 0.3.5+4 | BSD |
| crypto | 3.0.7 | BSD |
| cupertino_icons | 1.0.9 | MIT |
| fake_async | 1.3.3 | Apache-2.0 |
| ffi | 2.2.0 | BSD |
| file | 7.0.1 | BSD |
| file_picker | 8.3.7 | MIT |
| file_selector_linux | 0.9.4 | BSD |
| file_selector_macos | 0.9.5 | BSD |
| file_selector_platform_interface | 2.7.0 | BSD |
| file_selector_windows | 0.9.3+5 | BSD |
| fixnum | 1.1.1 | BSD |
| flutter | 0.0.0 | Apache-2.0 |
| flutter_lints | 4.0.0 | BSD |
| flutter_localizations | 0.0.0 | Apache-2.0 |
| flutter_markdown | 0.7.7+1 | BSD |
| flutter_plugin_android_lifecycle | 2.0.35 | BSD |
| flutter_slidable | 4.0.3 | MIT |
| flutter_test | 0.0.0 | Apache-2.0 |
| flutter_web_plugins | 0.0.0 | Apache-2.0 |
| hooks | 2.1.0 | BSD |
| http | 1.6.0 | BSD |
| http_parser | 4.1.2 | BSD |
| image_picker | 1.2.3 | Apache-2.0 |
| image_picker_android | 0.8.13+19 | Apache-2.0 |
| image_picker_for_web | 3.1.1 | BSD |
| image_picker_ios | 0.8.13+6 | Apache-2.0 |
| image_picker_linux | 0.2.2 | BSD |
| image_picker_macos | 0.2.2+1 | BSD |
| image_picker_platform_interface | 2.11.1 | BSD |
| image_picker_windows | 0.2.2 | BSD |
| intl | 0.20.3 | BSD |
| jni | 1.0.3 | BSD |
| jni_flutter | 1.0.2 | BSD |
| jni_util | 1.0.0 | BSD |
| leak_tracker | 11.0.2 | BSD |
| leak_tracker_flutter_testing | 3.0.10 | BSD |
| leak_tracker_testing | 3.0.2 | BSD |
| lints | 4.0.0 | BSD |
| local_auth | 2.3.0 | BSD |
| local_auth_android | 1.0.56 | BSD |
| local_auth_darwin | 1.6.1 | BSD |
| local_auth_platform_interface | 1.1.0 | BSD |
| local_auth_windows | 1.0.11 | BSD |
| logging | 1.3.0 | BSD |
| markdown | 7.3.1 | BSD |
| matcher | 0.12.20 | BSD |
| material_color_utilities | 0.13.0 | Apache-2.0 |
| meta | 1.19.0 | BSD |
| mime | 2.0.0 | BSD |
| nested | 1.0.0 | MIT |
| objective_c | 9.5.0 | BSD |
| open_filex | 4.7.0 | BSD |
| package_config | 3.0.0 | BSD |
| path | 1.9.1 | BSD |
| path_provider | 2.1.6 | BSD |
| path_provider_android | 2.3.1 | BSD |
| path_provider_foundation | 2.6.0 | BSD |
| path_provider_linux | 2.2.2 | BSD |
| path_provider_platform_interface | 2.1.3 | BSD |
| path_provider_windows | 2.3.0 | BSD |
| petitparser | 7.0.2 | MIT |
| platform | 3.1.6 | BSD |
| plugin_platform_interface | 2.1.8 | BSD |
| posix | 6.5.2 | MIT |
| provider | 6.1.5+1 | MIT |
| pub_semver | 2.2.0 | BSD |
| record_use | 1.1.0 | BSD |
| shared_preferences | 2.5.5 | BSD |
| shared_preferences_android | 2.4.27 | BSD |
| shared_preferences_foundation | 2.5.6 | BSD |
| shared_preferences_linux | 2.4.1 | BSD |
| shared_preferences_platform_interface | 2.4.2 | BSD |
| shared_preferences_web | 2.4.3 | BSD |
| shared_preferences_windows | 2.4.1 | BSD |
| sky_engine | 0.0.0 | Apache-2.0 |
| source_span | 1.10.2 | BSD |
| sqflite | 2.4.3 | BSD |
| sqflite_android | 2.4.3 | BSD |
| sqflite_common | 2.5.11 | BSD |
| sqflite_darwin | 2.4.3+1 | BSD |
| sqflite_platform_interface | 2.4.1 | BSD |
| stack_trace | 1.12.1 | BSD |
| stream_channel | 2.1.4 | BSD |
| string_scanner | 1.4.1 | BSD |
| syncfusion_flutter_core | 34.2.5 | Syncfusion 许可 |
| syncfusion_flutter_pdf | 34.2.5 | Syncfusion 许可 |
| synchronized | 3.4.1+2 | MIT |
| term_glyph | 1.2.2 | BSD |
| test_api | 0.7.12 | BSD |
| typed_data | 1.4.0 | BSD |
| url_launcher | 6.3.2 | BSD |
| url_launcher_android | 6.3.32 | BSD |
| url_launcher_ios | 6.4.1 | BSD |
| url_launcher_linux | 3.2.2 | BSD |
| url_launcher_macos | 3.2.5 | BSD |
| url_launcher_platform_interface | 2.3.2 | BSD |
| url_launcher_web | 2.4.3 | BSD |
| url_launcher_windows | 3.1.5 | BSD |
| uuid | 4.6.0 | MIT-ish |
| vector_math | 2.4.2 | BSD |
| vm_service | 15.2.0 | BSD |
| web | 1.1.1 | BSD |
| win32 | 5.15.0 | BSD |
| xdg_directories | 1.1.0 | BSD |
| xml | 7.0.1 | MIT |
| yaml | 3.1.3 | MIT-ish |

## 特别归属说明

### archive 4.2.0
`archive` 包包含以下上游实现/派生代码，需要保留归属：
- zlib.js：版权 I.M. Underwood / imaya，MIT
- JZLib：版权 ymnk / JCraft，2000-2011
- bzip2：版权 Julian Seward，1996-2010
- pointycastle：版权 Legion of the Bouncy Castle，MIT

### syncfusion_flutter_pdf 34.2.5
本组件使用 Syncfusion 许可，不是普通宽松开源许可证。若继续使用，请确保当前使用场景符合 Syncfusion 许可条款。

### Flutter / Flutter SDK / Sky Engine
Flutter 及相关 SDK 组件采用 Apache-2.0 许可。

### google_mlkit_text_recognition 0.16.0 / google_mlkit_commons 0.12.0
本机 OCR 能力。Flutter 插件层 Apache-2.0；Android 原生库 `com.google.mlkit:text-recognition-chinese:16.0.1` 同为 Apache-2.0（Google ML Kit）。仅在本 App 关闭「视觉支持」时被调用，用于把图片里的文字提取出来，识别在设备本地完成，不上传图片。

### 本项目说明
本项目自 v1.7.32 起包含本机 OCR 实现（Google ML Kit Text Recognition），此前版本图片能力仅涉及选图、保存与 base64 传输。
