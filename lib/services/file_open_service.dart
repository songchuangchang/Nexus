import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';

import 'logger_service.dart';
import 'platform_capabilities.dart';

/// 「用系统打开文件」的结果。
enum FileOpenStatus {
  /// 已交给系统处理。
  done,

  /// 当前平台没有任何打开通道（不该发生：Windows 有 explorer 降级，
  /// 真走到这说明平台矩阵漏了分支，按失败处理并留日志）。
  unsupportedPlatform,

  /// 有通道但调用失败（含 explorer 没能起进程）。
  failed,
}

class FileOpenResult {
  const FileOpenResult(this.status, this.message);

  final FileOpenStatus status;
  final String message;

  bool get ok => status == FileOpenStatus.done;
}

/// 起进程抽象：测试注入假实现，断言「Windows 降级确实去喊了 explorer.exe」
/// 而不依赖真起进程。签名对齐 Process.start 的最小子集。
typedef FileOpenSpawn = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// 统一的「用系统打开文件/文件夹」入口（M2）。
///
/// 手机走 open_filex；Windows 上 open_filex 没有实现（插件 pubspec 只声明
/// android/ios），降级为 explorer.exe——文件用默认关联程序打开、目录开
/// 资源管理器窗口。explorer.exe 的退出码不可靠（成功也常返回 1），所以
/// Windows 分支以「进程是否起得来」为准，不看退出码。
class FileOpenService {
  FileOpenService._();

  /// 测试注入：替代 Windows 分支的 Process.start。
  @visibleForTesting
  static FileOpenSpawn? debugSpawn;

  @visibleForTesting
  static void resetDebugSpawn() => debugSpawn = null;

  /// 打开 [path]（绝对路径）。签名保留 open_filex 的 [type] 参数（MIME），
  /// Windows 分支用不到它——explorer 按扩展名走系统关联。
  static Future<FileOpenResult> open(String path, {String? type}) async {
    if (PlatformCapabilities.supportsOpenFilex) {
      final r = await OpenFilex.open(path, type: type);
      if (r.type == ResultType.done) {
        return const FileOpenResult(FileOpenStatus.done, 'done');
      }
      return FileOpenResult(FileOpenStatus.failed, r.message);
    }
    if (PlatformCapabilities.os == 'windows') {
      try {
        final spawn = debugSpawn ??
            (exe, args) =>
                Process.start(exe, args, mode: ProcessStartMode.detached);
        await spawn('explorer.exe', [path]);
        LoggerService.instance
            .info('文件打开降级：explorer.exe ← $path', tag: 'FileOpen');
        return const FileOpenResult(FileOpenStatus.done, 'explorer');
      } catch (e) {
        LoggerService.instance
            .warn('explorer.exe 打开失败 $path：$e', tag: 'FileOpen');
        return FileOpenResult(FileOpenStatus.failed, '$e');
      }
    }
    LoggerService.instance.warn(
      '当前平台(${PlatformCapabilities.os})无文件打开通道：$path',
      tag: 'FileOpen',
    );
    return const FileOpenResult(
        FileOpenStatus.unsupportedPlatform, 'unsupported platform');
  }
}
