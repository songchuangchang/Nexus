import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/video_task.dart';
import '../services/attachment_service.dart';
import '../services/image_gen_service.dart';
import '../services/video_gen_service.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';
// build173（S13/S19b）：裸 toolresult 通道收口到同一个信封构造函数。
import 'builtin_plugins.dart' show toolResultTag;

/// build122：生成类内置插件（图片 / 视频）。
///
/// ## 为什么单独成文件
/// `builtin_plugins.dart` 已 1700+ 行。生成能力涉及两个服务、两种**明显不同的
/// 执行模型**（图片同步秒级 / 视频异步分钟级），塞进去只会让那个文件更难改；
/// 这里用独立的 `gen_plugins.dart`，只在注册表里挂两行。
///
/// ## 两个插件的执行模型差异（关键设计点）
/// - **图片**：同步等待（数秒~2 分钟），拿到文件后**直接写进消息的 generatedFiles**，
///   用户马上能在气泡里看到；
/// - **视频**：**绝不能同步等**——官方口径 1~5 分钟，ReAct 循环若阻塞会把整轮对话
///   卡死。因此只做「提交 + 落库」，随后交给「AI 视频」页的轮询器去续查、下载。
///   插件如实回灌 toolresult 告诉模型「任务已提交，稍后可在页面查看」。

/// 成本确认弹窗（图片/视频共用）。
///
/// 为什么必须确认：生成是**按张/按秒计费**的付费调用，用户在聊天里让模型生图时
/// 并不知道要花多少；不确认就静默扣费违反项目「花钱/破坏性操作必须弹确认」的规矩。
Future<bool> _confirmCost(
  BuildContext context, {
  required bool isZh,
  required String title,
  required String body,
}) async {
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(isZh ? '取消' : 'Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(isZh ? '继续生成' : 'Generate')),
      ],
    ),
  );
  return ok == true;
}

/// 统一的结果回灌（与 log_query 的 _finish 同构：工具结果必须让模型看得见）
///
/// build125：error/rejected 状态补 `is_error="true"`——与 MCP 通道的 toolresult 口径
/// 对齐（此前生成插件只写 `status="error"`，模型侧拿不到「这是失败」的显式信号，
/// 真机日志里表现为失败后继续换参数重试）。
void _finish(PluginContext pc, ReasoningStep? step, String pluginId,
    String tool, String status, String summary) {
  pc.updateReasoningStep(step, status: status, resultSummary: summary);
  final isError = status == 'error' || status == 'rejected';
  pc.addMessage(ChatMessage.create(
    conversationId: pc.assistantMsg.conversationId,
    role: MessageRole.user,
    // build173（S13/S19b）裸通道收口：这里原先自己拼外壳、正文只替 `<`
    // （`>`/`&`/`=` 原样透传，也没有 `encoding`/`trust`），改走同一个信封构造
    // 函数 ⇒ 转义 + 结构锁两道口径与 builtin_plugins 的 12 个调用点逐字节一致。
    // **不再**在这里预转义 summary：预转义再过一次外壳就是二次转义（`&amp;lt;`）。
    content: toolResultTag(
      pluginId: pluginId,
      tool: tool,
      attrs: {
        'status': status,
        if (isError) 'is_error': 'true',
      },
      body: summary,
    ),
  ));
}

/// build125：生成类插件失败的统一回灌文案。
///
/// 三个必须点（全部来自真机日志 nexus_export_2026-09-17T22-09 的实锤）：
/// ① **带上上游原文**：此前 `ImageGenException.detail` 被丢弃，日志与 toolresult 里
///    都只有「请求被拒（400）」→ 模型只能猜「是不是 quality 参数不对」，改成 medium
///    再试、又去搜一遍文档，4 轮全 400 仍无结论；
/// ② **明确禁止编造产物**：该日志里模型在失败后自行编出
///    `![Apocalyptic ruined city](https://cdn.openai.com/image_gen/...)` 假链接并宣称
///    「已生成」——用户看到的是假图链接；
/// ③ **连续失败达阈值即熔断**：同工具换 prompt 会让 E5 的「动作+参数指纹」熔断失效
///    （每次指纹都不同），必须按「本消息 + 工具」计数兜住（见 PluginContext.noteGenFailure）。
String _failSummary(
  PluginContext pc,
  bool isZh,
  String message,
  String? detail, {
  required String tool,
}) {
  final n = pc.noteGenFailure(tool);
  final b = StringBuffer(message);
  if (detail != null && detail.trim().isNotEmpty) {
    b.write(isZh ? '\n上游原文：$detail' : '\nUpstream: $detail');
  }
  b.write(isZh
      ? '\n不要编造图片/视频链接、不要声称已生成；请如实告知用户失败原因与可执行的修复动作。'
      : '\nDo not fabricate links or claim success; report the failure honestly.');
  if (n >= 2) {
    b.write(isZh
        ? '\n宿主熔断：本消息内该工具已连续失败 $n 次，判定不可用。不要再调用，直接基于已有信息答复用户。'
        : '\nCircuit open: $n consecutive failures — stop retrying.');
  }
  return b.toString();
}

// ============================================================================
// build131：参考图解析（图生图 / 图生视频共用）
// ============================================================================

/// 参考图来源——确认框里要如实写出来源（用户才知道花了钱买的是哪张图的结果）。
enum GenRefSource {
  /// 本次不传参考图（纯文生图 / 纯文生视频）。
  none,

  /// 本条消息里的图片附件。
  messageAttachment,

  /// 会话里更早的图（上一条消息发的、或上一次生成的）——`image="last"`。
  history,
}

/// 参考图解析失败类型（用于渲染回灌文案）。
enum GenRefError {
  /// 写了 image，但本条消息根本没有图片附件。
  noAttachment,

  /// 写的序号 / 文件名在本条消息的附件里找不到。
  notFound,

  /// 写了 image="last"，但会话里没有可复用的图。
  noHistory,
}

/// [pickGenRefImage] 的结果。
class GenRefPick {
  /// 命中的参考图；null = 本次按纯文生处理。
  final MessageAttachment? ref;

  /// 命中来源（[ref] 为 null 时无意义）。
  final GenRefSource source;

  /// 失败类型；null = 没有失败。
  final GenRefError? error;

  const GenRefPick._(this.ref, this.source, this.error);

  const GenRefPick.none() : this._(null, GenRefSource.none, null);

  GenRefPick.hit(MessageAttachment r, this.source)
      : ref = r,
        error = null;

  const GenRefPick.fail(GenRefError e)
      : ref = null,
        source = GenRefSource.none,
        error = e;
}

/// 历史候选图能取几张就够（只要最近一张用于 `image="last"`）。
/// 取多了要做同步 IO（existsSync/lengthSync），没有收益。
const int _kGenRefHistoryCap = 4;

const Set<String> _kImageExts = {
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
};

/// 把「会话里更早的图」摊平成候选列表，**最近优先**（纯函数，便于单测）。
///
/// 两个来源，按消息时间倒序扫描：
///   ① assistant 消息的 `generatedFiles`（取末项——最近生成的那张）；
///   ② 用户消息的图片附件。
/// 当前这一轮的 user / assistant 消息**不算历史**（它们的附件由 `current` 负责），
/// 通过 [currentUserId] / [currentAssistantId] 排除。
///
/// （build131）为什么需要它：用户最自然的说法是「把**刚才那张**改成油画风 /
/// 让上一张动起来」——指代的是历史消息或刚生成的图，而不是本条消息的附件。
/// 旧实现只认本条消息的附件，这类请求只能回灌「没有图片附件」，用户拿不到结果。
List<MessageAttachment> genRefHistoryOf(
  List<ChatMessage> messages, {
  String? currentUserId,
  String? currentAssistantId,
}) {
  final out = <MessageAttachment>[];
  for (var i = messages.length - 1; i >= 0; i--) {
    if (out.length >= _kGenRefHistoryCap) break;
    final m = messages[i];
    if (m.id == currentUserId || m.id == currentAssistantId) continue;
    if (m.role == MessageRole.assistant) {
      for (final p in m.generatedFiles.reversed) {
        final att = _imageAttachmentFromPath(p);
        if (att != null) {
          out.add(att);
          break;
        }
      }
    } else {
      for (final a in m.attachments) {
        if (a.type == AttachmentType.image && a.localPath != null) out.add(a);
      }
    }
  }
  return out;
}

/// [genRefHistoryOf] 的插件侧入口（带上本轮两条消息的 id 以便排除）。
List<MessageAttachment> genRefHistory(PluginContext pc) => genRefHistoryOf(
      pc.workingMessages,
      currentUserId: pc.userMsg?.id,
      currentAssistantId: pc.assistantMsg.id,
    );

/// 由本地路径合成一个图片附件（生成产物只有路径，附件模型需要 type/fileName）。
/// 非图片扩展名 / 文件已不存在 → null（生成目录可能被用户清理过）。
MessageAttachment? _imageAttachmentFromPath(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot).toLowerCase();
  if (!_kImageExts.contains(ext)) return null;
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return MessageAttachment(
      id: 'gen_ref_hist_${path.hashCode}',
      type: AttachmentType.image,
      fileName: name,
      localPath: path,
      sizeBytes: f.lengthSync(),
    );
  } catch (_) {
    return null;
  }
}

/// 解析 `<image_gen image="...">` / `<video_gen image="...">` 的参考图（纯函数）。
///
/// 规则与两个插件的 promptProtocol **严格一致**：
///   ① 未写 image：本条消息恰好 1 张图 → 默认用它；否则**不猜**（纯文生）；
///   ② `image="last"`（兼容中文「上一张」）→ [history] 里最近一张；
///   ③ `image="N"`：本条消息第 N 张（1 基）；越界 → [GenRefError.notFound]，
///      本条消息一张图都没有时 → [GenRefError.noAttachment]；
///   ④ `image="文件名"`：按文件名在本条消息附件里找。
///
/// （build131）**关键设计：宁可回灌错误，也不要静默降级。** 旧实现里「模型指定了
/// 参考图但没解析到」会直接把 refImg 留成 null ⇒ 用户说「改成油画风」却拿到一张
/// 全新的文生图，且全程没有任何提示。现在未命中的显式引用一律回灌，由模型决定
/// 「请用户重新附图」还是「去掉 image 走文生」。
GenRefPick pickGenRefImage({
  required List<MessageAttachment> current,
  required List<MessageAttachment> history,
  required String want,
}) {
  final w = want.trim();
  if (w.isEmpty) {
    if (current.length == 1) {
      return GenRefPick.hit(current.first, GenRefSource.messageAttachment);
    }
    return const GenRefPick.none();
  }
  final lower = w.toLowerCase();
  if (lower == 'last' || w == '上一张' || w == '刚才那张') {
    if (history.isEmpty) return const GenRefPick.fail(GenRefError.noHistory);
    return GenRefPick.hit(history.first, GenRefSource.history);
  }
  if (current.isEmpty) return const GenRefPick.fail(GenRefError.noAttachment);
  final idx = int.tryParse(w);
  if (idx != null) {
    if (idx >= 1 && idx <= current.length) {
      return GenRefPick.hit(current[idx - 1], GenRefSource.messageAttachment);
    }
    return const GenRefPick.fail(GenRefError.notFound);
  }
  final byName = current.where((a) => a.fileName == w).firstOrNull;
  if (byName != null) {
    return GenRefPick.hit(byName, GenRefSource.messageAttachment);
  }
  return const GenRefPick.fail(GenRefError.notFound);
}

/// 参考图解析失败时的回灌文案（两插件共用，只有动作名词不同）。
String genRefErrorText(
  GenRefError error, {
  required bool isZh,
  required String action, // '图生图' / '图生视频'
  required String pureAction, // '纯文生图' / '纯文生视频'
  required List<MessageAttachment> imgAtts,
  required String want,
}) {
  if (!isZh) {
    switch (error) {
      case GenRefError.noAttachment:
      case GenRefError.noHistory:
        return 'No reusable image found ($action). Ask the user to attach the '
            'image in a new message, or retry without the image attribute for '
            '$pureAction.';
      case GenRefError.notFound:
        return 'No image matching "$want" in this message. Available: '
            '${imgAtts.map((a) => a.fileName).join(', ')}';
    }
  }
  final available =
      imgAtts.isEmpty ? '（本条消息没有图片附件）' : imgAtts.map((a) => a.fileName).join('、');
  switch (error) {
    case GenRefError.noAttachment:
      return '本条消息没有图片附件，无法$action（历史消息里的图不算——要改历史图请写 image="last"）。'
          '请让用户把图作为附件重新发一次；若本来就想 $pureAction，请重新调用并**去掉 image 属性**。';
    case GenRefError.noHistory:
      return '会话里没有可复用的历史图片（用户还没发过、你也没生成过图），无法$action。'
          '请让用户把图作为附件发一次；若本来就想 $pureAction，请重新调用并**去掉 image 属性**。';
    case GenRefError.notFound:
      return '本条消息里找不到「$want」对应的图片。可用的有：$available'
          '（可用 1 基序号或文件名；要改历史图用 image="last"）。';
  }
}

// ============================================================================
// 图片生成
// ============================================================================

class ImageGenPlugin extends ReActPlugin {
  @override
  String get triggerType => 'image_gen';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.image_gen',
        name: '图片生成',
        version: '1.7.66',
        author: 'Nexus Team',
        description:
            '生成图片：文生图；用户发图后要改图（改风格/换背景/重画）时带 image= 走图生图。',
        homepage: 'https://nexus.local/plugins/image_gen',
        minAppVersion: '1.7.66',
        tags: ['内置', '生成', '图片'],
        extra: {
          'notWhen': '用户只是要文字描述/代码，或明确说不要图片时，不要生成',
          'cost': '按张计费（消耗当前 API 配置的额度）',
        },
        promptProtocol: '''
【图片生成】用户要求「画一张/生成图片/做张图」时输出：
  <image_gen prompt="画面描述（尽量具体：主体、风格、光线、构图）" size="1024x1024" n="1" quality="medium" />
- size 取 1024x1024 / 1024x1536（竖）/ 1536x1024（横）；n 为 1~4；quality 取 low/medium/high（可不写）。
- **图生图（你确实有这个能力，宿主走 POST {baseUrl}/v1/images/edits 的 multipart 上传）**：
  用户发图后说「改成油画风 / 换成夜景 / 把背景去掉 / 把这张图重画一遍 / 把刚才那张改成…」时，
  **必须显式写 image 属性**：
    <image_gen prompt="油画风格，保留原构图与主体" image="1" />
  image 取值三选一：
    · "1"/"2"/…——**本条消息**里图片附件的 1 基序号（按出现顺序）；
    · 附件文件名（本条消息带的图）；
    · "last"——**会话里最近一张图**（你上一次生成的图，或用户上一条消息发的图）。
      用户说「刚才那张 / 上一张 / 我前面发的图」时用它（历史消息里的图只能这样引用，写序号无效）。
  **纯文生图（不需要参考图）时绝对不要写 image**；本条消息恰好 1 张图且用户明显指的就是它时，
  image 可以省略（宿主默认用它）；带 ≥2 张图时必须写，不写宿主按文生图处理（不会替你猜）。
- 若你判断要改图、但本条消息没有附件且 image="last" 也没找到图，宿主会回灌「无法图生图」。
  此时请用户在消息里**把图作为附件重新发一次**（或先让你生成一张再改图）。
  **绝对不要说**「我没有上传图片/编辑图片的接口」「没法拿现有图片做输入」——能力是有的，
  缺的只是图本身；也不要因此改口去写一段文字描述代替生成。
- 宿主会先弹确认框征得用户同意（按张计费），同意后才生成；确认框里会写明用了哪张参考图。
- 生成成功后图片会直接显示在回答里，你**不要**再用文字描述画面内容，简单说一句「已生成」并说明可选尺寸/风格即可。
- 你上一轮生成的图**不会**自动成为下一轮的参考图：用户要改刚生成的那张，必须写 image="last"。
- 生图模型由「API 配置 → 文生图模型」决定（留空则回落到对话模型）。若宿主回灌 400/404
  （说明当前模型不是图像模型、或端点不支持），**不要**反复改 size/quality/prompt 重试——
  这是配置问题，直接让用户去「API 配置 → 文生图模型」填一个图像模型名（如 gpt-image-1 /
  dall-e-3 / grok-2-image / flux-schnell / doubao-seedream）。
- 不要编造图片链接（含 Markdown 图片语法）；只有宿主回灌了生成结果才算成功，失败就如实说明原因。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final prompt = (attrs['prompt'] as String? ?? '').trim();
    final size = (attrs['size'] as String? ?? '1024x1024').trim();
    final quality = (attrs['quality'] as String? ?? '').trim();
    final n = ((int.tryParse(attrs['n']?.toString() ?? '') ?? 1).clamp(1, 4));

    final step = pc.addReasoningStep(
      'image_gen',
      '${isZh ? '图片生成' : 'Image gen'} · ${prompt.length > 24 ? '${prompt.substring(0, 24)}…' : prompt}',
      status: 'running',
    );

    if (prompt.isEmpty) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          isZh
              ? '缺少 prompt 属性。正确写法：<image_gen prompt="一只橘猫坐在窗台" size="1024x1024" n="1" />'
              : 'Missing prompt attribute.');
      return;
    }

    // 生成端点需要 baseUrl/apiKey，当前会话没有可用配置时直接如实回灌，
    // 不要让上层抛空指针（默认不吞、错误可见）。
    final cfg = pc.conversationApiConfig;
    if (cfg == null) {
      _finish(pc, step, 'nexus.builtin.image_gen', 'image_gen', 'error',
          isZh ? '当前会话没有可用的 API 配置，无法调用图片生成端点。' : 'No API config available.');
      return;
    }

    // build125：能力位未开启时明确拒绝（与「AI 绘图」独立页的判定口径对齐）。
    // 此前聊天内**不校验**能力位 → 配置里没勾也会真发请求，用户看到的是一串
    // 莫名其妙的 400/403，而修复动作（去勾选开关）无人提示。
    if (!cfg.supportImageGen) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          isZh
              ? '当前 API 配置未开启「图片生成」能力。请到 设置 → API 配置 → 编辑该配置 → 生成能力，'
                  '勾选「图片生成」（并建议填写「文生图模型」）后重试。'
              : 'Image generation is disabled for the current API config.');
      return;
    }

    // build125：本消息内已连续失败 ≥2 次 → 熔断，不再弹成本确认框、不再发请求。
    if (pc.isGenCircuitOpen('image_gen')) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          isZh
              ? '宿主熔断：本消息内图片生成已连续失败多次，判定不可用。不要再调用；'
                  '请如实告知用户失败原因（多为模型/端点不支持，需在 API 配置里指定文生图模型）。'
              : 'Circuit open: image generation unavailable in this message.');
      return;
    }

    // build129：图生图——走 /v1/images/edits（multipart），非 generations
    //（「改成油画风」这类需求只能靠 edits 端点，靠 prompt 描述原图既贵又不准）。
    // build131：解析统一走 [pickGenRefImage]（新增 image="last" 历史图/刚生成的图），
    // 且**不再静默降级**——显式指定却没解析到一律回灌。
    final imgAtts = (pc.userMsg?.attachments ?? const <MessageAttachment>[])
        .where((a) => a.type == AttachmentType.image && a.localPath != null)
        .toList();
    final wantImg = (attrs['image'] as String? ?? '').trim();
    final pick = pickGenRefImage(
      current: imgAtts,
      history: genRefHistory(pc),
      want: wantImg,
    );
    if (pick.error != null) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          genRefErrorText(
            pick.error!,
            isZh: isZh,
            action: '图生图',
            pureAction: '纯文生图',
            imgAtts: imgAtts,
            want: wantImg,
          ));
      return;
    }
    final refImg = pick.ref;

    String? refB64;
    if (refImg != null) {
      final sz = refImg.sizeBytes ?? 0;
      if (sz > 8 * 1024 * 1024) {
        _finish(
            pc,
            step,
            'nexus.builtin.image_gen',
            'image_gen',
            'error',
            isZh
                ? '参考图过大（${(sz / 1024 / 1024).toStringAsFixed(1)}MB），请压缩到 8MB 以内再试。'
                : 'Reference image too large (max 8MB).');
        return;
      }
      refB64 = await AttachmentService().imageToBase64(refImg);
      if (refB64 == null || refB64.isEmpty) {
        _finish(
            pc,
            step,
            'nexus.builtin.image_gen',
            'image_gen',
            'error',
            isZh
                ? '参考图读取失败（文件可能已被系统清理），请让用户重新发送该图片。'
                : 'Failed to read the reference image.');
        return;
      }
    }

    // 参考图是 async 读盘（imageToBase64），之后再碰 context 必须显式校验；
    // 同时把 running 的步骤收尾——不留下「永远转圈」的假进行中状态。
    if (!context.mounted) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          isZh ? '界面已关闭，本次图片生成已取消。' : 'UI closed; cancelled.');
      return;
    }

    final ok = await _confirmCost(
      context,
      isZh: isZh,
      title: isZh ? '生成图片？' : 'Generate image?',
      body: isZh
          ? '将调用当前 API 配置的${refImg != null ? '图生图（images/edits）' : '文生图'}端点生成 $n 张图片（$size${quality.isEmpty ? '' : ' · $quality'}）。\n\n'
              '${refImg != null ? '参考图：${refImg.fileName}${pick.source == GenRefSource.history ? '（会话里最近一张）' : ''}\n\n' : ''}'
              '这会消耗你的 API 额度（按张计费）。'
          : 'Generate $n image(s) at $size. This consumes your API quota (per image).',
    );
    if (!ok) {
      _finish(pc, step, 'nexus.builtin.image_gen', 'image_gen', 'rejected',
          isZh ? '用户取消了本次图片生成' : 'User cancelled image generation');
      return;
    }

    try {
      final result = await ImageGenService.generate(
        cfg,
        prompt: prompt,
        size: size,
        n: n,
        quality: quality.isEmpty ? null : quality,
        inputImageBase64: refB64,
        inputImageName: refImg?.fileName,
      );
      // 关键：写进 generatedFiles（**不是** attachments）——生成产物只做本地展示，
      // 绝不能回灌成下一轮的多模态输入（见 chat_message.dart 的字段注释）。
      pc.assistantMsg.generatedFiles
          .addAll(result.files.map((f) => f.path));
      await pc.saveAssistantContent(force: true);
      pc.clearGenFailure('image_gen');
      _finish(
        pc,
        step,
        'nexus.builtin.image_gen',
        'image_gen',
        'done',
        isZh
            ? '已生成 ${result.files.length} 张图片，已显示在本条回答中（用户可直接查看/分享）。'
            : 'Generated ${result.files.length} image(s).',
      );
    } on ImageGenException catch (e) {
      _finish(
          pc,
          step,
          'nexus.builtin.image_gen',
          'image_gen',
          'error',
          _failSummary(pc, isZh, e.message, e.detail, tool: 'image_gen'));
      pc.showSnackBar(e.message, error: true);
    } catch (e) {
      final msg = isZh ? '图片生成失败：$e' : 'Image generation failed: $e';
      _finish(pc, step, 'nexus.builtin.image_gen', 'image_gen', 'error',
          _failSummary(pc, isZh, msg, null, tool: 'image_gen'));
      pc.showSnackBar(msg, error: true);
    }
  }
}

// ============================================================================
// 视频生成
// ============================================================================

class VideoGenPlugin extends ReActPlugin {
  @override
  String get triggerType => 'video_gen';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.video_gen',
        name: '视频生成',
        version: '1.7.66',
        author: 'Nexus Team',
        description:
            '提交视频任务：文生视频；给一张图让它动起来（图生视频）时带 image=，异步生成后在「AI 视频」页查看。',
        homepage: 'https://nexus.local/plugins/video_gen',
        minAppVersion: '1.7.66',
        tags: ['内置', '生成', '视频'],
        extra: {
          'notWhen': '用户只是想要文字/图片时不要提交视频任务',
          'cost': '按秒计费（5s/10s 差价明显，pro 模式更贵）',
          'async': '生成需 1~5 分钟，宿主只做提交，不在对话里等待',
        },
        promptProtocol: '''
【视频生成】用户要求「生成视频/做个视频/让这张图动起来」时输出：
  <video_gen prompt="画面与运镜描述" seconds="5" size="1280x720" mode="std" />
- seconds 取 5 或 10（**按秒计费**，10 秒约双倍）；size 取 1280x720 / 1920x1080 / 720x1280（竖）；mode 取 std / pro。
- **图生视频（你确实有这个能力）**：用户发图后说「让它动起来 / 用这张图生成视频 / 把刚才那张做成视频」时，
  **必须显式写 image 属性**：
    <video_gen prompt="镜头缓慢推近，头发随风轻摆" image="1" seconds="5" />
  image 取值三选一：`"1"`/`"2"`/…（**本条消息**图片附件的 1 基序号）、附件文件名、
  `"last"`（**会话里最近一张图**——你上一次生成的图，或用户上一条消息发的图；
  用户说「刚才那张 / 上一张 / 我前面发的图」时用它）。
  **纯文生视频不要写 image**；本条消息恰好 1 张图且明显指它时可省略（宿主默认用它）；
  带 ≥2 张图时必须写，不写宿主按文生视频处理（不会替你猜）。
- 「图生视频」时若找不到图（本条消息没附件、image="last" 也没命中），宿主会回灌「无法图生视频」→
  请用户在消息里**把图作为附件重新发一次**，**不要说**「我没有接口」；确认框里会写明用了哪张图。
- 宿主会先弹确认框告知费用，同意后**只提交任务**（生成要 1~5 分钟，不在对话里等待）。
- 提交成功后你应如实告知用户：「任务已提交，生成中，完成后可在『AI 视频』页查看/播放」，**不要**声称已经生成完成，也不要编造视频链接。
- 视频模型由「API 配置 → 文生视频模型」决定（留空则回落到对话模型）。若宿主回灌 400/404
  （说明当前模型不是视频模型、或端点不支持），**不要**反复改 seconds/size/mode/prompt 重试，
  也**不要**去联网搜「怎么给 video_gen 传 model 参数」——宿主不支持在标签里指定模型。
  这是配置问题：直接让用户去「API 配置 → 文生视频模型」填一个视频模型名
  （如 grok-imagine-video / kling-video-o1 / sora-2），或让用户说一声由你改。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final prompt = (attrs['prompt'] as String? ?? '').trim();
    final seconds = (int.tryParse(attrs['seconds']?.toString() ?? '') ?? 5);
    final size = (attrs['size'] as String? ?? '1280x720').trim();
    final mode = (attrs['mode'] as String? ?? 'std').trim();

    final step = pc.addReasoningStep(
      'video_gen',
      '${isZh ? '视频生成' : 'Video gen'} · ${prompt.length > 20 ? '${prompt.substring(0, 20)}…' : prompt}',
      status: 'running',
    );

    if (prompt.isEmpty) {
      _finish(
          pc,
          step,
          'nexus.builtin.video_gen',
          'video_gen',
          'error',
          isZh
              ? '缺少 prompt 属性。正确写法：<video_gen prompt="宇航员在月面行走" seconds="5" />'
              : 'Missing prompt attribute.');
      return;
    }

    // 同图片：配置缺失时如实回灌而非抛空指针
    final cfg = pc.conversationApiConfig;
    if (cfg == null) {
      _finish(pc, step, 'nexus.builtin.video_gen', 'video_gen', 'error',
          isZh ? '当前会话没有可用的 API 配置，无法提交视频任务。' : 'No API config available.');
      return;
    }

    // build125：能力位未开启 → 明确拒绝（与图片生成同一口径）。
    if (!cfg.supportVideoGen) {
      _finish(
          pc,
          step,
          'nexus.builtin.video_gen',
          'video_gen',
          'error',
          isZh
              ? '当前 API 配置未开启「视频生成」能力。请到 设置 → API 配置 → 编辑该配置 → 生成能力，'
                  '勾选「视频生成」后重试。'
              : 'Video generation is disabled for the current API config.');
      return;
    }

    // build125：本消息内已连续失败 ≥2 次 → 熔断（同图片生成，见 _failSummary 注释）。
    if (pc.isGenCircuitOpen('video_gen')) {
      _finish(
          pc,
          step,
          'nexus.builtin.video_gen',
          'video_gen',
          'error',
          isZh
              ? '宿主熔断：本消息内视频任务提交已连续失败多次，判定不可用。不要再调用；请如实告知用户失败原因。'
              : 'Circuit open: video generation unavailable in this message.');
      return;
    }

    // build129：图生视频——先定参考图，再谈钱（成本框里要如实写出「用了哪张图」）。
    //
    // 为什么必须有「未指定但恰好 1 张图 → 默认用它」这条：AI 通常拿不到附件文件名
    // （图片走视觉通道，不带名字），若只支持显式指定，这个能力在真机上几乎永远
    // 触发不到——而「让这张图动起来」正是用户最自然的说法。多图时不猜（猜错要按秒
    // 计费），改为要求显式指定。
    // build131：解析统一走 [pickGenRefImage]（新增 image="last"=会话里最近一张图），
    // 且显式指定却没解析到一律回灌，**不再静默降级成文生视频**。
    final imgAtts = (pc.userMsg?.attachments ?? const <MessageAttachment>[])
        .where((a) => a.type == AttachmentType.image && a.localPath != null)
        .toList();
    final wantImg = (attrs['image'] as String? ?? '').trim();
    final pick = pickGenRefImage(
      current: imgAtts,
      history: genRefHistory(pc),
      want: wantImg,
    );
    if (pick.error != null) {
      _finish(
          pc,
          step,
          'nexus.builtin.video_gen',
          'video_gen',
          'error',
          genRefErrorText(
            pick.error!,
            isZh: isZh,
            action: '图生视频',
            pureAction: '纯文生视频',
            imgAtts: imgAtts,
            want: wantImg,
          ));
      return;
    }
    final refImg = pick.ref;

    String? refB64;
    if (refImg != null) {
      // 上游对 input_reference 普遍限 10MB 上下：本地先拦，避免白等 1~5 分钟后拿 400
      final sz = refImg.sizeBytes ?? 0;
      if (sz > 8 * 1024 * 1024) {
        _finish(
            pc,
            step,
            'nexus.builtin.video_gen',
            'video_gen',
            'error',
            isZh
                ? '参考图过大（${(sz / 1024 / 1024).toStringAsFixed(1)}MB），请压缩到 8MB 以内再试。'
                : 'Reference image too large (max 8MB).');
        return;
      }
      refB64 = await AttachmentService().imageToBase64(refImg);
      if (refB64 == null || refB64.isEmpty) {
        _finish(
            pc,
            step,
            'nexus.builtin.video_gen',
            'video_gen',
            'error',
            isZh
                ? '参考图读取失败（文件可能已被系统清理），请让用户重新发送该图片。'
                : 'Failed to read the reference image.');
        return;
      }
    }

    // 参考图是 async 读盘（imageToBase64），之后再碰 context 必须显式校验；
    // 同时把 running 的步骤收尾——不留下「永远转圈」的假进行中状态。
    if (!context.mounted) {
      _finish(
          pc,
          step,
          'nexus.builtin.video_gen',
          'video_gen',
          'error',
          isZh ? '界面已关闭，本次视频生成已取消。' : 'UI closed; cancelled.');
      return;
    }

    final ok = await _confirmCost(
      context,
      isZh: isZh,
      title: isZh ? '生成视频？' : 'Generate video?',
      body: isZh
          ? '将提交一个 $seconds 秒的视频生成任务（$size · $mode）。\n\n'
              '${refImg != null ? '参考图：${refImg.fileName}（图生视频${pick.source == GenRefSource.history ? '，会话里最近一张' : ''}）\n\n' : ''}'
              '⚠️ 视频**按秒计费**，且生成需要 1~5 分钟；提交后可在「AI 视频」页查看进度与成品。\n\n确认消耗 API 额度？'
          : 'Submit a $seconds-second video task ($size · $mode). Billed per second; takes 1-5 min.',
    );
    if (!ok) {
      _finish(pc, step, 'nexus.builtin.video_gen', 'video_gen', 'rejected',
          isZh ? '用户取消了本次视频生成' : 'User cancelled video generation');
      return;
    }

    try {
      final snap = await VideoGenService.submit(
        cfg,
        prompt: prompt,
        seconds: seconds,
        size: size,
        mode: mode,
        inputImageBase64: refB64,
      );
      // 落库：视频是异步作业（1~5 分钟 + 上游 URL 仅 24h），必须持久化才能在
      // 切后台/杀进程后继续查——否则钱已花、成品拿不到。
      await pc.storage.saveVideoTask(VideoTask.create(
          apiConfigId: cfg.id,
          remoteTaskId: snap.id,
          prompt: prompt,
          // build129：存**实际使用**的视频模型（原为 cfg.model = 对话模型）
          model: cfg.effectiveVideoModel,
          seconds: seconds,
          size: size,
          mode: mode,
          state: snap.state.name,
        ));
      pc.clearGenFailure('video_gen');
      _finish(
        pc,
        step,
        'nexus.builtin.video_gen',
        'video_gen',
        'submitted',
        isZh
            ? '视频任务已提交（任务号 ${snap.id}），生成约需 1~5 分钟。'
                '已完成的部分请到「AI 视频」页查看进度并在完成后播放/保存。'
                '请如实告知用户「任务已提交、生成中」，不要声称已完成。'
            : 'Video task submitted (id ${snap.id}); takes 1-5 min.',
      );
    } on VideoGenException catch (e) {
      _finish(pc, step, 'nexus.builtin.video_gen', 'video_gen', 'error',
          _failSummary(pc, isZh, e.message, e.detail, tool: 'video_gen'));
      pc.showSnackBar(e.message, error: true);
    } catch (e) {
      final msg = isZh ? '视频任务提交失败：$e' : 'Video submit failed: $e';
      _finish(pc, step, 'nexus.builtin.video_gen', 'video_gen', 'error',
          _failSummary(pc, isZh, msg, null, tool: 'video_gen'));
      pc.showSnackBar(msg, error: true);
    }
  }
}
