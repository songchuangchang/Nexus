import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_config.dart';

/// 模型能力记忆 —— 「不猜，但记住」。
///
/// ## 背景（build97 的教训，不能忘）
/// `ApiConfig.detectVisionSupport` 是**白名单启发式**，用 `contains` 匹配模型族。
/// 曾经试图把它改成「乐观默认 true」——结果 `glm-5.3` 这类**纯文本推理模型**
/// 被 `glm-5` 族整族误命中，用户每次带图都白发一次注定 400 的请求再降级 OCR。
/// 结论：**启发式必须保持保守**，白名单不能放宽成乐观默认。
///
/// ## 但保守的代价是「漏新模型」，而且漏了之后没人记住
/// `qwen3-vl` / `internvl` / `llava` 等新视觉模型不在白名单里，用户只能手动打开开关。
/// 而**手动开启这个结论没有任何地方记住**：
/// `api_config_edit_screen` 在「选模型 / 选模板」时会用 `detectVisionSupport` 重算
/// `_supportVision`（171 / 400 / 420 / 682 / 1025 五处），于是用户下次再选一次同款模型，
/// 开关被悄悄改回 false，图片又静默退回 OCR —— 用户只会觉得「这模型怎么忽好忽坏」。
///
/// 本类补上「记住」这一半，与启发式组成**双向学习**：
///   · [learnVision] `true`  ← 带图请求**真实成功过**（图片确实按图片发出去了）
///   · [learnVision] `false` ← 被上游按 `_isVisionRejection()` 明确拒绝过
/// 解析优先级：**记忆 > 白名单启发式**（见 [resolveVision]）。
///
/// ## 口径边界（避免误伤，这几条是刻意的）
/// 1. 记忆只用来**给出默认值**。用户在设置页显式拨动的开关存在
///    `ApiConfig.supportVision` 里，永远优先 —— 换了网关后旧结论不该硬挡用户。
/// 2. 按 **modelId** 记忆（与 `detectVisionSupport` 同粒度）。不同网关对同一模型的
///    透传能力可能不同，所以「学到的 false」不会阻止用户手动开启（见第 1 条兜底）。
/// 3. key 带版本号 `v1`，将来口径变了可以直接换前缀作废旧记忆，不必写迁移。
class ModelCapabilityMemory {
  ModelCapabilityMemory._();

  static const String _visionPrefix = 'cap.vision.v1.';

  static String _key(String modelId) =>
      '$_visionPrefix${modelId.trim().toLowerCase()}';

  /// 读记忆。返回 `null` = **从未观测过**（此时才回落到启发式），
  /// 与「观测过、结论是 false」严格区分 —— 这是双向学习能成立的前提。
  static Future<bool?> loadVision(
    String modelId, {
    SharedPreferences? prefs,
  }) async {
    if (modelId.trim().isEmpty) return null;
    final p = prefs ?? await SharedPreferences.getInstance();
    return p.getBool(_key(modelId));
  }

  /// 记下一次**观测结论**（不是用户偏好 —— 用户偏好在 `ApiConfig.supportVision`）。
  ///
  /// 已经一致时不重复落盘：这个方法会在每次带图请求成功后被调用，
  /// 不加这道判断会变成每次请求都写一次磁盘。
  static Future<void> learnVision(
    String modelId,
    bool supported, {
    SharedPreferences? prefs,
  }) async {
    if (modelId.trim().isEmpty) return;
    final p = prefs ?? await SharedPreferences.getInstance();
    final k = _key(modelId);
    if (p.getBool(k) == supported) return;
    await p.setBool(k, supported);
  }

  /// 解析该模型的视觉能力默认值：**记忆优先，无记忆才用白名单启发式**。
  static Future<bool> resolveVision(
    String modelId, {
    SharedPreferences? prefs,
  }) async {
    final learned = await loadVision(modelId, prefs: prefs);
    return learned ?? ApiConfig.detectVisionSupport(modelId);
  }

  /// 一次性读出整张记忆表。
  ///
  /// 给设置页用：它的解析发生在 `onChanged` / `DropdownMenuItem` 回调里，
  /// 那里不能 `await`，所以 initState 先把表读进内存，再用 [resolveVisionSync] 同步解析。
  static Future<Map<String, bool>> loadVisionMap({
    SharedPreferences? prefs,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final out = <String, bool>{};
    for (final k in p.getKeys()) {
      if (k.startsWith(_visionPrefix)) {
        final v = p.getBool(k);
        if (v != null) out[k.substring(_visionPrefix.length)] = v;
      }
    }
    return out;
  }

  /// 同步解析（[memory] 由 [loadVisionMap] 预先读好）。
  static bool resolveVisionSync(String modelId, Map<String, bool> memory) =>
      memory[modelId.trim().toLowerCase()] ??
      ApiConfig.detectVisionSupport(modelId);
}
