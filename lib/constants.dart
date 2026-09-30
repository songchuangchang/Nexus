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
            '1.7.118+175', // build175：老装机记住的旧私有仓下载地址在启动时被摘掉（摘空才回落内置公开仓源），远程数据包热更从此真能生效；消息下方四个动作键与「token 详情」的触摸区补到 48dp；「思考过程」标题砍掉重复字；检查更新失败的日志不再写「属预期」。
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

/// 热更载荷验签的**内置信任锚**：Ed25519 公钥，裸 32 字节 = 64 位十六进制小写。
///
/// 唯一所有者是本文件；消费点只有 `lib/services/pack_signature.dart` 一处。
/// 它是 44 字节 SPKI DER（`302a300506032b6570032100` + 32 字节裸钥）的后 32 字节，
/// 前缀已核对——**存裸钥不存 DER**：验签库吃的就是裸 32 字节，多一层 DER 只有两个
/// 能写歪的地方（前缀抄错 / 切片 off-by-one），少一个。
///
/// 私钥不在仓库、不在本机、不参与任何构建步骤（用户自持）。因此
/// ① 这里不存在"导出"路径，② 判据只能用测试现场造的一次性密钥对签样本，
/// ③ 于是必须有反向锁钉住本常量 == 这 64 位十六进制，防止有人把锚换成自己的钥匙
///    （锁在 `test/build174_pack_signature_test.dart` 的 ⑦ 组）。
///
/// 语义（fail-closed，见 `data_pack_protocol.dart` 的 `dataPackSignatureGate`）：
/// 四条**远程**载荷（api_templates / builtin_prompts / mcp_catalog / rules）必须带
/// 一把由这把公钥验得过的 `signature`，否则不应用、回落内置。APK 内的内置资产
/// 走不到这道闸（它们由 APK 签名保护），这是有意的，见同一文件的 ⑤ 组反向闸。
const String kDataPackSignaturePublicKeyHex =
    '837ece0d7abc5c4e4ccdedd59f5c9cb80d04ebd16ecba8e28fb5e371563e15c4';

/// **签发授权闸**的公钥（ECDSA P-256 公钥，DER 的 base64）——不是签名私钥，别混。
///
/// 分工：上面那把是"这份载荷是不是钥匙主人签的"（**验内容**，装在每个 APK 里）；
/// 这一把是"这一次签发的授权票是不是路由器上的闸发的"（**验授权**，只在发版工具里用）。
/// 闸的私钥住路由器 `/etc/pack-gate/gate.ec`，永不离开那台设备。
///
/// 为什么必须钉在代码里而不是放一个本地文件：票是**离线验**的，如果公钥从一个笔电上的
/// 文件读，改那个文件就等于自己当了闸 ⇒ 这道闸当场失效。钉进仓 ⇒ 换闸公钥必须改代码、
/// 过一次审查、重新出包，这正是要的那道"不能悄悄发生"。
///
/// 空串是**有意的初始状态**（2026-09-29 装到一半：路由器侧已就绪、闸密钥尚未生成）。
/// 空 ⇒ `verifyTicketOffline` 直接拒（fail-closed）：没有可信公钥就一张票都不认。
/// 跑完 `install_on_router.sh` 会打印 `GATE_PUB_DER_B64=…`，把那串填进来即可启用。
///
/// 2026-09-30 00:3x 已钉入实钥：GL-MT3600BE 上 `/etc/pack-gate/gate.pub` 的公钥，
/// 由用户本人在 Git Bash 里跑 `deploy_gate.sh` 生成并贴回（**公钥可贴，secret 不可贴**）。
/// 换这把 = 换闸，必须走代码审查；笔电本地改文件伪造不了（读的是这个常量）。
const String kPackGatePublicKeyDerB64 =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEGelM47sBVBsuyg6eZ5scM2qjnADGfS4rtZBw2ZnrF6Y/dn5TxWPsZdKemQKWqArJS6L/Pn/dbJGyoms+gHaSXg==';

