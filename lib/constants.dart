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
            '1.7.116+173', // build172：照片与截图的文字读取修好（编排/深研路径此前拿不到图内文字）；远程扫描规则改走数据闸门；自更新缺校验和时不再静默放行；模板 baseUrl 被远程改写要你确认；数据包更新提示改回事实。
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
