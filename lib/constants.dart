/// 全局常量集中管理
///
/// 放在独立文件里避免循环依赖（BackupService ↔ LoggerService）。
///
/// O10 版本号单一源治理：构建期可用 `--dart-define=APP_VERSION=x.y.z+n` 注入；
/// 未注入时回落到下方兜底字面量。兜底字面量必须与 pubspec.yaml 的 version 保持一致，
/// 由 test/version_sync_test.dart 强制断言（不一致则测试失败，不允许再靠人记）。
library constants;

const String kAppVersionConst = String.fromEnvironment(
  'APP_VERSION',
  defaultValue:
            '1.7.113+170', // build170：修复回答里混入模型自述、短英文回答整条消失；灵动岛新增「等你回答」状态。
);

/// build115（typed 内核最小切片）：答案来源开关。
///
/// true  → 裸文本兜底的答案来源改为「content 段」（模型给用户的正文，经内核
///         分类：裸文本与 <answer> 块归 answer、<thinking> 块归 thinking），
///         不再使用「reasoning_content + content 混流拼接」的文本——后者正是
///         「结论混着思考」的根因（实测 28 批中 26 批涉及此类）。
/// false → 一键回退旧行为（混流 parsed.thinking 当答案），用于线上应急。
///
/// 说明：本开关只影响「答案从哪来」，不影响流式显示 / 工具分发 / 净化链。
const bool kUseTypedKernel = true;
