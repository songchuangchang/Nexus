import 'package:shared_preferences/shared_preferences.dart';

/// build138（甲1）：AI 文件工作区「权限档位」——唯一真相源。
///
/// 立项前的事实（缺失 UI 评审查实）：`_wsConfirm()` 是硬编码「每次必弹」，
/// 全库搜 permissionTier / autoApprove / 档位字段 0 命中 ⇒ 用户没有任何办法
/// 在「反复迭代同一个文件」这种场景下少按几次确认；而交接单的原话是
/// 「权限档位必须与 UI 同批，只做服务无 UI＝用户够不着＝等于不存在」，
/// 只做 UI 不落消费点则是本项目反复踩的「看起来已经接好了」。
/// 所以本文件同时给出：档位定义、**纯函数判定**（可单测）、持久化读写。
enum WsPermissionTier {
  /// 每次确认（默认）——与线上现状逐字节一致，零回归。
  alwaysAsk(0),

  /// 自动改文件：新建与替换式修改不再询问；覆盖已有文件与删除仍弹。
  autoEdit(1),

  /// 全自动：写 / 改 / 覆盖一律直接落盘；**删除永远弹**，这一档不给关。
  autoAll(2);

  const WsPermissionTier(this.value);

  /// 落库存的数字（不是 enum index，避免以后调顺序把老用户设置改语义）。
  final int value;

  static WsPermissionTier fromValue(int? v) => WsPermissionTier.values.firstWhere(
        (t) => t.value == v,
        // 未识别的值一律退回最严的「每次确认」——宁可多弹一次，不可少弹一次。
        orElse: () => WsPermissionTier.alwaysAsk,
      );
}

/// 三种要人工批准的工作区操作。
enum WsOpKind { write, patch, delete }

/// 判定：这次操作要不要弹确认框。纯函数，不碰 IO，方便单测把三档矩阵钉死。
///
/// [isOverwrite] 只对 write 有意义（`ws_write overwrite="true"`）；
/// patch 天生就是改已存在的文件，按「修改」而非「覆盖」处理
/// —— 因为它是事务式补丁：find 不唯一/空改/超限都会整体拒绝，一个字节都不动。
bool wsNeedsConfirm(
  WsPermissionTier tier, {
  required WsOpKind kind,
  bool isOverwrite = false,
}) {
  switch (kind) {
    // 删除＝不可逆，任何档位都强制确认（设计红线，不给关）。
    case WsOpKind.delete:
      return true;
    case WsOpKind.write:
      switch (tier) {
        case WsPermissionTier.alwaysAsk:
          return true;
        // 自动改文件：新建放行，覆盖已有文件仍弹。
        case WsPermissionTier.autoEdit:
          return isOverwrite;
        case WsPermissionTier.autoAll:
          return false;
      }
    case WsOpKind.patch:
      switch (tier) {
        case WsPermissionTier.alwaysAsk:
          return true;
        case WsPermissionTier.autoEdit:
        case WsPermissionTier.autoAll:
          return false;
      }
  }
}

/// 档位持久化：复用 SharedPreferences（与「允许 AI 读取日志」开关同一条路），
/// 不新增 DB 列 ⇒ 不用走建表/升级/回滚那套五保险。
class WorkspacePermissionStore {
  static const String key = 'wsPermissionTier';

  static Future<WsPermissionTier> load() async {
    final prefs = await SharedPreferences.getInstance();
    return WsPermissionTier.fromValue(prefs.getInt(key));
  }

  static Future<void> save(WsPermissionTier tier) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, tier.value);
  }
}

/// 档位文案（zh/en 内联，与本项目近期设置页同一做法，不进 arb 生成物）。
({String title, String desc}) wsPermissionTierLabel(
        WsPermissionTier tier, bool isZh) {
  switch (tier) {
    case WsPermissionTier.alwaysAsk:
      return (
        title: isZh ? '每次确认（默认）' : 'Ask every time (default)',
        desc: isZh
            ? 'AI 每次写/改/删文件都弹确认框，你逐个批准。今天的线上行为。'
            : 'AI asks before every write, patch and delete. Same as today.',
      );
    case WsPermissionTier.autoEdit:
      return (
        title: isZh ? '自动改文件' : 'Auto-edit files',
        desc: isZh
            ? '新建与修改不再询问；删除、覆盖已有文件仍弹确认。适合反复迭代同一个文件。'
            : 'Create and patch without asking; delete and overwrite still confirm.',
      );
    case WsPermissionTier.autoAll:
      return (
        title: isZh ? '全自动' : 'Full auto',
        desc: isZh
            ? '写、改、覆盖一律直接落盘。删除仍会弹确认 —— 这一层不给关掉。'
            : 'Write, patch and overwrite go straight to disk. Delete always confirms.',
      );
  }
}
