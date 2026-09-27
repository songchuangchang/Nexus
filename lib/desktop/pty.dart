/// B5 终端最小样本：ConPTY（Windows 伪控制台）直连 kernel32，dart:ffi 手写
/// 绑定，不引 win32 三方包。能力面：spawn（命令行进伪控制台）/ 收字节流 /
/// 发按键 / resize / 退出码。UI 集成（终端面板）在样本验证之后另起层。
///
/// Win64 ABI 注：CreatePseudoConsole/ResizePseudoConsole 的 COORD 是 4 字节
/// POD，按值传参等价于一个 Uint32（低 16 位 X、高 16 位 Y），这里按整数声明，
/// 绕开 dart:ffi 结构体按值传参的版本差异。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const int _kExtendedStartupInfoPresent = 0x00080000;
const int _kProcThreadAttributePseudoConsole = 0x00020016;
const int _kStillActive = 259;

final class _StartupInfoEx extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Uint16> lpReserved;
  external Pointer<Uint16> lpDesktop;
  external Pointer<Uint16> lpTitle;
  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;
  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  @IntPtr()
  external int hStdInput;
  @IntPtr()
  external int hStdOutput;
  @IntPtr()
  external int hStdError;
  external Pointer<Uint8> lpAttributeList;
}

final class _ProcessInformation extends Struct {
  @IntPtr()
  external int hProcess;
  @IntPtr()
  external int hThread;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createPseudoConsole = _kernel32.lookupFunction<
    Int32 Function(Uint32, IntPtr, IntPtr, Uint32, Pointer<IntPtr>),
    int Function(int, int, int, int, Pointer<IntPtr>)>('CreatePseudoConsole');
final _resizePseudoConsole = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('ResizePseudoConsole');
final _closePseudoConsole = _kernel32.lookupFunction<Void Function(IntPtr),
    void Function(int)>('ClosePseudoConsole');
final _createPipe = _kernel32.lookupFunction<
    Int32 Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Uint8>, Uint32),
    int Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Uint8>,
        int)>('CreatePipe');
final _initAttrList = _kernel32.lookupFunction<
    Int32 Function(Pointer<Uint8>, Uint32, Uint32, Pointer<UintPtr>),
    int Function(Pointer<Uint8>, int, int,
        Pointer<UintPtr>)>('InitializeProcThreadAttributeList');
final _updateAttr = _kernel32.lookupFunction<
    Int32 Function(Pointer<Uint8>, Uint32, UintPtr, IntPtr, UintPtr,
        Pointer<Uint8>, Pointer<Uint8>),
    int Function(Pointer<Uint8>, int, int, int, int, Pointer<Uint8>,
        Pointer<Uint8>)>('UpdateProcThreadAttribute');
final _deleteAttrList = _kernel32.lookupFunction<Void Function(Pointer<Uint8>),
    void Function(Pointer<Uint8>)>('DeleteProcThreadAttributeList');
final _createProcessW = _kernel32.lookupFunction<
    Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint8>,
        Pointer<Uint8>, Int32, Uint32, Pointer<Uint16>, Pointer<Uint16>,
        Pointer<_StartupInfoEx>, Pointer<_ProcessInformation>),
    int Function(Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint8>,
        Pointer<Uint8>, int, int, Pointer<Uint16>, Pointer<Uint16>,
        Pointer<_StartupInfoEx>, Pointer<_ProcessInformation>)>(
    'CreateProcessW');
final _readFile = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>,
        Pointer<Uint8>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>,
        Pointer<Uint8>)>('ReadFile');
final _writeFile = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>,
        Pointer<Uint8>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>,
        Pointer<Uint8>)>('WriteFile');
final _waitForSingleObject = _kernel32.lookupFunction<
    Uint32 Function(IntPtr, Uint32),
    int Function(int, int)>('WaitForSingleObject');
final _getExitCodeProcess = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint32>),
    int Function(int, Pointer<Uint32>)>('GetExitCodeProcess');
final _terminateProcess = _kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('TerminateProcess');
final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('CloseHandle');
final _getStdHandle = _kernel32.lookupFunction<IntPtr Function(Uint32),
    int Function(int)>('GetStdHandle');
final _setStdHandle = _kernel32.lookupFunction<Int32 Function(Uint32, IntPtr),
    int Function(int, int)>('SetStdHandle');
final _createFileW = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Uint8>, Uint32,
        Uint32, IntPtr),
    int Function(Pointer<Uint16>, int, int, Pointer<Uint8>, int, int,
        int)>('CreateFileW');
final _allocConsole =
    _kernel32.lookupFunction<Int32 Function(), int Function()>('AllocConsole');
final _freeConsole =
    _kernel32.lookupFunction<Int32 Function(), int Function()>('FreeConsole');
final _getConsoleWindow =
    _kernel32.lookupFunction<IntPtr Function(), int Function()>('GetConsoleWindow');
final _user32 = DynamicLibrary.open('user32.dll');
final _showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
    int Function(int, int)>('ShowWindow');
final _isWindowVisible = _user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('IsWindowVisible');

/// 本进程当前是否挂着控制台。真 GUI 发布形态应为 false（走 AllocConsole 分支），
/// flutter test / dart run 下为 true。探针与测试靠它确认走的是哪条路。
bool hostHasConsole() => _getConsoleWindow() != 0;

/// 本进程控制台窗口是否可见。AllocConsole 之后我们立刻 SW_HIDE，
/// 这里应为 false —— 真窗口探针用它断言「不闪窗」。
bool hostConsoleVisible() {
  final hwnd = _getConsoleWindow();
  if (hwnd == 0) return false;
  return _isWindowVisible(hwnd) != 0;
}

const int _kStdInput = 0xFFFFFFF6;
const int _kStdOutput = 0xFFFFFFF5;
const int _kStdError = 0xFFFFFFF4;

// dart:ffi 不带 calloc/malloc（在 package:ffi 里，不能为它动 pubspec）：
// 用 kernel32 LocalAlloc(LPTR=0x40 零初始化)/LocalFree 自己实现最小分配器。
final _localAlloc = _kernel32.lookupFunction<
    Pointer<Uint8> Function(Uint32, UintPtr),
    Pointer<Uint8> Function(int, int)>('LocalAlloc');
final _localFree = _kernel32.lookupFunction<
    Pointer<Uint8> Function(Pointer<Uint8>),
    Pointer<Uint8> Function(Pointer<Uint8>)>('LocalFree');

final class _LocalAllocator {
  const _LocalAllocator();

  Pointer<T> allocate<T extends NativeType>(int byteCount) {
    final p = _localAlloc(0x0040, byteCount);
    if (p == nullptr) throw StateError('LocalAlloc failed');
    return p.cast();
  }

  void free(Pointer<NativeType> pointer) {
    _localFree(pointer.cast());
  }
}

const _alloc = _LocalAllocator();


Pointer<Uint16> _wide(String s) {
  final units = s.codeUnits;
  final p = _alloc.allocate<Uint16>(sizeOf<Uint16>() * (units.length + 1));
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  p[units.length] = 0;
  return p;
}

int _packCoord(int x, int y) => (x & 0xFFFF) | ((y & 0xFFFF) << 16);

class PtyException implements Exception {
  PtyException(this.op, this.code);
  final String op;
  final int code;
  @override
  String toString() => 'PtyException: $op failed (code=$code)';
}

/// 读侧 isolate 入口：阻塞 ReadFile 循环转发输出字节。
/// ConPTY 管道的 EOF 只在 ClosePseudoConsole 之后到来，所以退出检测不在这里。
/// Windows 句柄是进程级资源，isolate 间传 int 值合法。
void _readerLoop((SendPort, int) args) {
  final (port, hOutRead) = args;
  final buf = _alloc.allocate<Uint8>(sizeOf<Uint8>() * (65536));
  final nRead = _alloc.allocate<Uint32>(sizeOf<Uint32>() * (1));
  try {
    for (;;) {
      final ok = _readFile(hOutRead, buf, 65536, nRead, nullptr);
      if (ok == 0 || nRead.value == 0) break;
      port.send(('data', buf.asTypedList(nRead.value)));
    }
  } finally {
    _alloc.free(buf);
    _alloc.free(nRead);
  }
}

/// 退出侧 isolate 入口：阻塞等子进程退出，回报退出码。
void _waiterLoop((SendPort, int) args) {
  final (port, hProcess) = args;
  final code = _alloc.allocate<Uint32>(sizeOf<Uint32>() * (1));
  try {
    _waitForSingleObject(hProcess, 0xFFFFFFFF); // INFINITE
    if (_getExitCodeProcess(hProcess, code) != 0) {
      port.send(('exit', code.value));
    } else {
      port.send(('error', 'GetExitCodeProcess failed'));
    }
  } finally {
    _alloc.free(code);
  }
}

/// 一个活着的伪控制台会话。
class WinPty {
  WinPty._({
    required this.pid,
    required int hPC,
    required int hInWrite,
    required int hProcess,
    required int hThread,
    required ReceivePort recv,
    required this.consoleAllocated,
  })  : _hPC = hPC,
        _hInWrite = hInWrite,
        _hProcess = hProcess,
        _hThread = hThread,
        _recv = recv;

  final int pid;

  /// 本次 spawn 是否走了 AllocConsole 分支（父进程本来没控制台，
  /// 比如真 GUI 发布形态）。测试与真窗口探针靠它确认走的是哪条路。
  final bool consoleAllocated;
  final int _hPC;
  final int _hInWrite;
  final int _hProcess;
  final int _hThread;
  final ReceivePort _recv;

  final _out = StreamController<Uint8List>();
  final _exit = Completer<int>();
  StreamSubscription? _recvSub;
  bool _disposed = false;

  /// 子进程输出的原始字节流（含 ANSI 转义；着色/光标解析是 UI 层的事）。
  Stream<Uint8List> get output => _out.stream;

  Future<int> get exitCode => _exit.future;

  bool get alive => !_exit.isCompleted;

  /// spawn：cmdline 进伪控制台（形如 'cmd.exe /c echo hi'）。
  /// cols/rows 是初始终端尺寸。
  static Future<WinPty> spawn({
    required String command,
    int cols = 80,
    int rows = 24,
    String? cwd,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('ConPTY 仅 Windows');
    }
    final hPipeConIn = _alloc.allocate<IntPtr>(sizeOf<IntPtr>() * (1)); // conpty 读：我们的按键
    final hPipeOurWrite = _alloc.allocate<IntPtr>(sizeOf<IntPtr>() * (1));
    final hPipeOurRead = _alloc.allocate<IntPtr>(sizeOf<IntPtr>() * (1)); // 我们读：子进程输出
    final hPipeConOut = _alloc.allocate<IntPtr>(sizeOf<IntPtr>() * (1));
    final hPC = _alloc.allocate<IntPtr>(sizeOf<IntPtr>() * (1));
    final attrSize = _alloc.allocate<UintPtr>(sizeOf<UintPtr>() * (1));
    final si = _alloc.allocate<_StartupInfoEx>(sizeOf<_StartupInfoEx>() * (1));
    final pi = _alloc.allocate<_ProcessInformation>(sizeOf<_ProcessInformation>() * (1));
    Pointer<Uint16> cmdBuf = nullptr;
    Pointer<Uint16> cwdBuf = nullptr;
    Pointer<Uint8> attrList = nullptr;
    try {
      if (_createPipe(hPipeConIn, hPipeOurWrite, nullptr, 0) == 0) {
        throw PtyException('CreatePipe(in)', 0);
      }
      if (_createPipe(hPipeOurRead, hPipeConOut, nullptr, 0) == 0) {
        throw PtyException('CreatePipe(out)', 0);
      }
      final hr = _createPseudoConsole(
          _packCoord(cols, rows), hPipeConIn.value, hPipeConOut.value, 0, hPC);
      if (hr != 0) {
        _closeHandle(hPipeConIn.value);
        _closeHandle(hPipeOurWrite.value);
        _closeHandle(hPipeOurRead.value);
        _closeHandle(hPipeConOut.value);
        throw PtyException('CreatePseudoConsole', hr);
      }
      // conpty 已持有两份句柄，我们手里的 conpty 侧端口立刻关掉。
      _closeHandle(hPipeConIn.value);
      _closeHandle(hPipeConOut.value);

      _initAttrList(nullptr, 1, 0, attrSize);
      attrList = _alloc.allocate<Uint8>(sizeOf<Uint8>() * (attrSize.value));
      if (_initAttrList(attrList, 1, 0, attrSize) == 0) {
        throw PtyException('InitializeProcThreadAttributeList', 0);
      }
      if (_updateAttr(attrList, 0, _kProcThreadAttributePseudoConsole,
              hPC.value, sizeOf<IntPtr>(), nullptr, nullptr) ==
          0) {
        throw PtyException('UpdateProcThreadAttribute', 0);
      }
      si.ref.cb = sizeOf<_StartupInfoEx>();
      si.ref.lpAttributeList = attrList;
      cmdBuf = _wide(command);
      cwdBuf = cwd == null ? nullptr : _wide(cwd);
      // ConPTY 接管子进程 std 句柄的前提：父进程此刻的 std 句柄是控制台类型。
      // 父进程 std 被重定向（flutter test 管道、dart run 转发、IDE 捕获）时，
      // 子进程会绕过伪控制台直接写父进程的管道/文件（实测：attribute 合法、
      // CreateProcess 成功，但 echo 落到父进程 stdout，pty 管道只有模式字节）。
      // 对策：CreateProcessW 瞬间把本进程 std 句柄换成 CONIN$/CONOUT$，返回后
      // 立即还原。窗口期微秒级；无控制台时 AllocConsole 一个并立刻隐藏。
      final savedStd = <int>[
        _getStdHandle(_kStdInput),
        _getStdHandle(_kStdOutput),
        _getStdHandle(_kStdError),
      ];
      var conOut = 0;
      var conIn = 0;
      var consoleAllocated = false;
      final conOutName = _wide(r'CONOUT$');
      final conInName = _wide(r'CONIN$');
      void openConsoleHandles() {
        conOut = _createFileW(conOutName, 0xC0000000, 3, nullptr, 3, 0, 0);
        conIn = _createFileW(conInName, 0xC0000000, 3, nullptr, 3, 0, 0);
      }

      try {
        openConsoleHandles();
        if (conOut <= 0 || conIn <= 0) {
          if (_allocConsole() != 0) {
            consoleAllocated = true;
            final hwnd = _getConsoleWindow();
            if (hwnd != 0) _showWindow(hwnd, 0); // SW_HIDE：避免测试时闪窗
            openConsoleHandles();
          }
        }
        if (conOut <= 0 || conIn <= 0) {
          throw PtyException('OpenConsoleHandles', 0);
        }
        _setStdHandle(_kStdInput, conIn);
        _setStdHandle(_kStdOutput, conOut);
        _setStdHandle(_kStdError, conOut);
        try {
          if (_createProcessW(nullptr, cmdBuf, nullptr, nullptr, 0,
                  _kExtendedStartupInfoPresent, nullptr, cwdBuf, si, pi) ==
              0) {
            throw PtyException('CreateProcessW', 0);
          }
        } finally {
          _setStdHandle(_kStdInput, savedStd[0]);
          _setStdHandle(_kStdOutput, savedStd[1]);
          _setStdHandle(_kStdError, savedStd[2]);
        }
      } finally {
        if (conOut > 0) _closeHandle(conOut);
        if (conIn > 0) _closeHandle(conIn);
        _alloc.free(conOutName);
        _alloc.free(conInName);
        if (consoleAllocated) _freeConsole();
      }

      final recv = ReceivePort();
      final pty = WinPty._(
        pid: pi.ref.dwProcessId,
        hPC: hPC.value,
        hInWrite: hPipeOurWrite.value,
        hProcess: pi.ref.hProcess,
        hThread: pi.ref.hThread,
        recv: recv,
        consoleAllocated: consoleAllocated,
      );
      await Isolate.spawn(
          _readerLoop, (recv.sendPort, hPipeOurRead.value));
      await Isolate.spawn(_waiterLoop, (recv.sendPort, pi.ref.hProcess));
      pty._recvSub = recv.listen((msg) {
        if (msg is (String, Uint8List) && msg.$1 == 'data') {
          pty._out.add(msg.$2);
        } else if (msg is (String, int) && msg.$1 == 'exit') {
          if (!pty._exit.isCompleted) pty._exit.complete(msg.$2);
        } else if (msg is (String, String) && msg.$1 == 'error') {
          if (!pty._exit.isCompleted) {
            pty._exit.completeError(StateError(msg.$2));
          }
        }
      });
      return pty;
    } finally {
      _alloc.free(hPipeConIn);
      _alloc.free(hPipeOurWrite);
      _alloc.free(hPipeOurRead);
      _alloc.free(hPipeConOut);
      _alloc.free(hPC);
      _alloc.free(attrSize);
      _alloc.free(si);
      _alloc.free(pi);
      if (cmdBuf != nullptr) _alloc.free(cmdBuf);
      if (cwdBuf != nullptr) _alloc.free(cwdBuf);
      if (attrList != nullptr) {
        _deleteAttrList(attrList);
        _alloc.free(attrList);
      }
    }
  }

  /// 发按键/输入字节（调用方自己带 \r 或 \r\n）。
  void write(List<int> bytes) {
    if (_disposed) throw StateError('已关闭');
    final buf = _alloc.allocate<Uint8>(sizeOf<Uint8>() * (bytes.length));
    final n = _alloc.allocate<Uint32>(sizeOf<Uint32>() * (1));
    try {
      for (var i = 0; i < bytes.length; i++) {
        buf[i] = bytes[i];
      }
      if (_writeFile(_hInWrite, buf, bytes.length, n, nullptr) == 0) {
        throw PtyException('WriteFile', 0);
      }
    } finally {
      _alloc.free(buf);
      _alloc.free(n);
    }
  }

  /// 改终端尺寸；HRESULT 非 0 抛 PtyException。
  void resize(int cols, int rows) {
    if (_disposed) throw StateError('已关闭');
    final hr = _resizePseudoConsole(_hPC, _packCoord(cols, rows));
    if (hr != 0) {
      throw PtyException('ResizePseudoConsole', hr);
    }
  }

  /// 关会话：子进程还活着就 TerminateProcess，再收所有句柄。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (alive) {
      final code = _alloc.allocate<Uint32>(sizeOf<Uint32>() * (1));
      if (_getExitCodeProcess(_hProcess, code) != 0 &&
          code.value == _kStillActive) {
        _terminateProcess(_hProcess, 1);
      }
      _alloc.free(code);
      _waitForSingleObject(_hProcess, 5000);
    }
    _closePseudoConsole(_hPC);
    _closeHandle(_hInWrite);
    _closeHandle(_hProcess);
    _closeHandle(_hThread);
    await _recvSub?.cancel();
    _recv.close();
    // StreamController.close() 的 Future 要等 done 事件被投递；从没监听过
    // output 时永远等不到（实测挂死），所以有监听才 await。
    if (_out.hasListener) {
      await _out.close();
    } else {
      _out.close();
    }
    if (!_exit.isCompleted) _exit.complete(-1);
  }
}
