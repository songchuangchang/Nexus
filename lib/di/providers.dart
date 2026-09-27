import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../plugins/plugin_registry.dart';
import '../providers/chat_skin_provider.dart';
import '../providers/font_size_provider.dart';
import '../providers/locale_provider.dart';
import '../services/api_service.dart';
import '../services/app_download_service.dart';
import '../services/live_task_wiring.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';

/// v1.7.24 (#12)：集中式 DI 层。
///
/// 决策见 `docs/DI_EVALUATION.md`：**保持 provider 方案**（不引入 GetIt / Riverpod）。
/// 理由：72 处 read/watch 消费点 + 30+ 文件迁移成本高，当前架构无痛点。
///
/// 所有根级 provider 在此集中定义，`main.dart` 只负责组装。
List<SingleChildWidget> buildAppProviders({
  required LocaleProvider localeProvider,
  required FontSizeProvider fontSizeProvider,
  required ChatSkinProvider chatSkinProvider,
  required PluginRegistry pluginRegistry,
}) {
  return [
    ChangeNotifierProvider.value(value: localeProvider),
    ChangeNotifierProvider.value(value: fontSizeProvider),
    ChangeNotifierProvider.value(value: chatSkinProvider),
    ChangeNotifierProvider.value(value: StorageService.instance),
    ChangeNotifierProvider(create: (_) => ApiService()),
    // build142（灵动岛）：在这里挂投影监听，而不是往下载服务里塞通知代码 ——
    // 服务不该知道通知的存在，「什么算进行中」也只能有一个裁决点（教训 #62）。
    ChangeNotifierProvider(create: (_) {
      final svc = AppDownloadService();
      LiveTaskWiring.bindAppDownloads(svc);
      return svc;
    }),
    ChangeNotifierProvider.value(value: LoggerService.instance),
    ChangeNotifierProvider.value(value: pluginRegistry),
  ];
}
