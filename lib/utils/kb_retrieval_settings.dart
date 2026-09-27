import 'package:shared_preferences/shared_preferences.dart';

import '../services/rag_service.dart';

/// build140（P0 缺口⑤）：知识库**检索阈值**（`minScore`）从"写死在代码里"变成可调。
///
/// 接线状态（本类已全仓接通，两条腿都在）：
///  1. **消费点**：`chat_screen_message.dart` 的 `_buildKnowledgeContext()` 每轮回答前
///     `load()` 一次，传给 `RagService.retrieveWithDiagnostics(minScore:)`，
///     并在"一个库都没命中"时打日志把当前阈值写进去（否则调高之后用户只会看到
///     「知识库没生效」，无从下手）；
///  2. **入口**：`knowledge_base_screen.dart` 列表页 AppBar 的
///     `Icons.filter_alt_outlined`（滑条 + `describe()` 档位说明 + 恢复默认）。
/// 这两处由 `test/build140_dead_caps_test.dart` 用源码锚点钉住——
/// 阈值这类"写死也不会报错"的参数，最容易在某次重构里被悄悄换回常量。
///
/// 为什么走 SharedPreferences 而不是给 `KnowledgeBase` 加一列：
///  - 新列要动 DB 五保险 + 迁移四同步（建表 / onUpgrade / `_ensureColumn` / 备份 schema /
///    完整性测试），而这条参数的失败模式是**全局性**的（embedding 模型换了、库大了 ⇒
///    阈值过高检不到 / 过低检进一堆不相干的），不是"这个库特殊"；
///  - 用户真正需要的是"检不到 ⇒ 调低一点"这一个动作，一个全局旋钮就够了。
///    真要做按库覆盖，再把这一格搬进 `knowledge_bases` 表（见难项移交清单）。
///
/// 默认值必须与 `RagService.kDefaultMinScore` 同源：两处各写 0.15，早晚会漂。
class KbRetrievalSettings {
  KbRetrievalSettings._();

  static const String prefKey = 'kb_min_score';

  /// 可调区间。
  ///
  /// 上限不到 1：余弦相似度 ≥0.9 基本等于"切片就是原句"，把它当阈值会让知识库
  /// 在几乎所有问题上检不到东西；下限不为 0：0 会把负相关的切片也塞进上下文
  /// （按分数排序后 topK 仍会取到，等于白烧 token）。
  static const double min = 0.02;
  static const double max = 0.60;

  /// 落库前夹紧：滑杆给的值 + 手输的值都过这一道（唯一实现）。
  static double clampScore(double v) {
    if (v.isNaN) return kDefault;
    return v < min ? min : (v > max ? max : v);
  }

  /// 未设置时的缺省 = RagService 的写死值 ⇒ 老用户升级后行为**逐字不变**，
  /// 而且"默认是多少"这个问题全仓库只有一个答案。
  static double get kDefault => RagService.kDefaultMinScore;

  static Future<double> load(SharedPreferences prefs) async =>
      clampScore(prefs.getDouble(prefKey) ?? kDefault);

  static Future<void> save(SharedPreferences prefs, double v) =>
      prefs.setDouble(prefKey, clampScore(v));

  /// 给用户看的一句话：这一档大概意味着什么（阈值是纯数字，不解释没人调得动）。
  static String describe(double v, {required bool zh}) {
    if (v <= 0.10) {
      return zh
          ? '很宽松：几乎每轮都会注入资料，可能混进不相干的内容'
          : 'Very loose: almost every turn gets injected material, including noise';
    }
    if (v <= 0.25) {
      return zh
          ? '常用档：只要与问题有些相关就会注入（默认附近）'
          : 'Usual: injects anything reasonably related to the question (near default)';
    }
    if (v <= 0.45) {
      return zh
          ? '较严格：只注入明显对得上的资料，检出的条数会明显变少'
          : 'Strict: only clearly matching chunks; expect far fewer hits';
    }
    return zh
        ? '非常严格：基本只有近乎原句的切片才会命中，知识库可能形同关闭'
        : 'Very strict: only near-verbatim chunks match; the KB may act disabled';
  }
}
