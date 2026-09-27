import 'package:uuid/uuid.dart';

/// build122：视频生成任务（本地持久化）。
///
/// ## 为什么必须落库（而不是只放在内存里）
///
/// 视频生成是**异步任务制**：提交后要 1~5 分钟才出结果，且**上游结果 URL 只保留
/// 24 小时**。如果任务只活在内存里：
/// - 用户切后台/杀进程 → 任务凭空消失，钱已经花了却拿不到成品；
/// - 上游 URL 过期前没下载 → 结果永久丢失。
/// 因此把「任务状态 + 远端 URL + 本地已落盘路径」持久化，App 重开后续查续下。
///
/// ## 字段口径
/// - [state] 用与 `VideoTaskState.name` **同名**的字符串（queued/processing/
///   completed/failed/unknown）——避免再造一张「枚举 ↔ 字符串」映射表（教训 #62：
///   同一语义多处各写一份必然漂移）；
/// - [resultUrl] 是**上游临时 URL**（24h），[localPath] 才是我们能长期依赖的东西。
class VideoTask {
  /// 本地主键
  final String id;

  /// 提交该任务用的 API 配置（换 key 后仍能追溯是哪个配置产生的）
  final String apiConfigId;

  /// 上游返回的任务 id（查询/续查用）
  final String remoteTaskId;

  final String prompt;
  final String model;
  final int seconds;
  final String size;
  final String mode;

  /// queued / processing / completed / failed / unknown
  final String state;

  /// 上游结果 URL（**24 小时有效期**，仅作下载来源与排查线索）
  final String resultUrl;

  /// 已下载到本地的文件路径（空串＝尚未落盘）
  final String localPath;

  /// 失败原因（面向用户的中文提示）
  final String errorMessage;

  final DateTime createdAt;
  final DateTime updatedAt;

  const VideoTask({
    required this.id,
    required this.apiConfigId,
    required this.remoteTaskId,
    required this.prompt,
    this.model = '',
    this.seconds = 5,
    this.size = '1280x720',
    this.mode = 'std',
    this.state = 'queued',
    this.resultUrl = '',
    this.localPath = '',
    this.errorMessage = '',
    required this.createdAt,
    required this.updatedAt,
  });

  /// 新建任务（本地 id 自动生成）
  factory VideoTask.create({
    required String apiConfigId,
    required String remoteTaskId,
    required String prompt,
    String model = '',
    int seconds = 5,
    String size = '1280x720',
    String mode = 'std',
    String state = 'queued',
  }) {
    final now = DateTime.now();
    return VideoTask(
      id: const Uuid().v4(),
      apiConfigId: apiConfigId,
      remoteTaskId: remoteTaskId,
      prompt: prompt,
      model: model,
      seconds: seconds,
      size: size,
      mode: mode,
      state: state,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 终态判定：completed / failed 之外的都还需要继续轮询
  bool get isTerminal => state == 'completed' || state == 'failed';

  /// 已完成且成品已落盘（可播放）
  bool get isReady => state == 'completed' && localPath.isNotEmpty;

  VideoTask copyWith({
    String? state,
    String? resultUrl,
    String? localPath,
    String? errorMessage,
    DateTime? updatedAt,
    String? remoteTaskId,
  }) {
    return VideoTask(
      id: id,
      apiConfigId: apiConfigId,
      remoteTaskId: remoteTaskId ?? this.remoteTaskId,
      prompt: prompt,
      model: model,
      seconds: seconds,
      size: size,
      mode: mode,
      state: state ?? this.state,
      resultUrl: resultUrl ?? this.resultUrl,
      localPath: localPath ?? this.localPath,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'apiConfigId': apiConfigId,
        'remoteTaskId': remoteTaskId,
        'prompt': prompt,
        'model': model,
        'seconds': seconds,
        'size': size,
        'mode': mode,
        'state': state,
        'resultUrl': resultUrl,
        'localPath': localPath,
        'errorMessage': errorMessage,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory VideoTask.fromMap(Map<String, dynamic> map) => VideoTask(
        id: (map['id'] as String?) ?? '',
        apiConfigId: (map['apiConfigId'] as String?) ?? '',
        remoteTaskId: (map['remoteTaskId'] as String?) ?? '',
        prompt: (map['prompt'] as String?) ?? '',
        model: (map['model'] as String?) ?? '',
        seconds: (map['seconds'] as num?)?.toInt() ?? 5,
        size: (map['size'] as String?) ?? '1280x720',
        mode: (map['mode'] as String?) ?? 'std',
        state: (map['state'] as String?) ?? 'unknown',
        resultUrl: (map['resultUrl'] as String?) ?? '',
        localPath: (map['localPath'] as String?) ?? '',
        errorMessage: (map['errorMessage'] as String?) ?? '',
        // 老数据缺时间戳时给一个确定的兜底，避免解析期抛异常丢掉整条任务
        createdAt: DateTime.tryParse((map['createdAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: DateTime.tryParse((map['updatedAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
