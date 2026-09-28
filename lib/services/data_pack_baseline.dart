/// 数据包「上次已应用的 dataVersion」持久化基线（X11 根因修复的共享地基）。
///
/// 为什么需要它：X11 的闸门基准原来是 `appVersion`（内置数据随 App 发布，
/// 内置版本 = App 版本），而四份载荷的 version 停在 1.7.32/1.7.37，
/// 全部低于 App 的 1.7.114 ⇒ 每个用户恒判旧、远程热更从未生效。
/// 改成**每包独立持久化**「上次已应用的 dataVersion」之后：
///  - 载荷版本与 App 版本解耦（日期式/语义式都能用）；
///  - 同版本重复拉取视为幂等重放，照常接受（规则/模板每轮扫描都要重放）；
///  - 只有**严格更旧**才拒绝（防降级重放）。
///
/// 谁用：[DataPackService] 三个既有包 + LocalScanService 的 rules.json（S21）。
/// 存储键：`dataPack.appliedBaseline.<packId>`（SharedPreferences，与
/// DataPackPrefKeys 同一存储，clearApplied 时必须一并清除）。
library data_pack_baseline;

import 'package:shared_preferences/shared_preferences.dart';

/// 每包基线的存储键前缀（实现细节，外部只用下面三个函数）。
const String kDataPackBaselinePrefix = 'dataPack.appliedBaseline.';

/// 读取某数据包「上次已应用的 dataVersion」。
/// 从未应用过（新装 / 刚 clearApplied）→ 返回空串，调用方据此跳过 notNewer 比较。
Future<String> readAppliedBaseline(String packId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('$kDataPackBaselinePrefix$packId') ?? '';
}

/// 记录某数据包本次已应用的 dataVersion。
/// **只在闸门放行且 applyPayload 成功之后调用**；失败/拒绝不得记录，
/// 否则一次坏载荷会把自己的版本钉进基线、挡住后面的正确版本。
Future<void> writeAppliedBaseline(String packId, String dataVersion) async {
  final v = dataVersion.trim();
  if (v.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('$kDataPackBaselinePrefix$packId', v);
}

/// 清除某包的基线（用户在界面放弃/清除该包远程载荷时调用）。
/// 清除后下次拉取视为首次应用。
Future<void> clearAppliedBaseline(String packId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('$kDataPackBaselinePrefix$packId');
}
