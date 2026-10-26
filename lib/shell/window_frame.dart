import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';

/// Whether the window wears VoxCordis' own title bar ([WindowFrame]) or the
/// system's. Kept as a flag file next to the settings rather than in them:
/// the Linux runner (my_application.cc) reads it before the window exists,
/// to pick a frame the title bar can be hidden from, and it applies before
/// the chats are unlocked.
class TitleBarChoice with WindowListener {
  TitleBarChoice._();

  static final _instance = TitleBarChoice._();

  /// True for the system's own bar; VoxCordis' bar unless the flag file
  /// says otherwise.
  static final system = ValueNotifier<bool>(true);

  /// Maximised or full screen: no corners and no top resize strip.
  static final maximized = ValueNotifier<bool>(false);
  static final focused = ValueNotifier<bool>(true);

  /// Windows: the runner (flutter_window.cpp) answers for VoxCordis'
  /// maximise button, so Windows 11 shows Snap Layouts over it. Then the
  /// pointer there never reaches Flutter, and the runner reports it here as
  /// (hover, pressed).
  static const _window = MethodChannel('voxcordis/window');
  static final maxButtonState = ValueNotifier<(bool, bool)>((false, false));
  static List<double>? _maxButton;

  /// Where the maximise button is, in the window's physical pixels; null
  /// when VoxCordis' bar is gone.
  static void reportMaxButton(Rect? rect) {
    if (!Platform.isWindows) return;
    final next = rect == null
        ? null
        : [rect.left, rect.top, rect.right, rect.bottom];
    if (listEquals(next, _maxButton)) return;
    _maxButton = next;
    _window.invokeMethod('maxButton', next).catchError((Object e) {
      debugPrint('Snap Layouts unavailable: $e');
    });
  }

  /// Only Windows and Linux draw their own; macOS keeps its bar.
  static bool get supported => Platform.isWindows || Platform.isLinux;

  static File? _flag;

  /// Reads the choice and hides the system bar before the first frame.
  static Future<void> load(Directory supportDir) async {
    if (!supported) return;
    _flag = File(p.join(supportDir.path, 'system-title-bar'));
    if (Platform.isWindows) {
      _window.setMethodCallHandler((call) async {
        if (call.method == 'maxButtonState' && call.arguments is List) {
          final [hover as bool, down as bool] = call.arguments as List;
          maxButtonState.value = (hover, down);
        }
      });
    }
    system.value = await _flag!.exists();
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(_instance);
    } on Object catch (e) {
      debugPrint('Window hooks unavailable: $e');
      system.value = true;
      return;
    }
    if (!system.value) await _apply();
  }

  static Future<void> set({required bool systemBar}) async {
    if (!supported || systemBar == system.value) return;
    system.value = systemBar;
    try {
      if (systemBar) {
        await _flag?.writeAsString('1');
      } else if (await _flag?.exists() ?? false) {
        await _flag!.delete();
      }
    } on FileSystemException catch (e) {
      debugPrint('Title bar choice not saved: $e');
    }
    await _apply();
  }

  static Future<void> _apply() async {
    try {
      await windowManager.setTitleBarStyle(
        system.value ? TitleBarStyle.normal : TitleBarStyle.hidden,
      );
    } on Object catch (e) {
      debugPrint('Title bar unchanged: $e');
    }
  }

  static Future<void> _refresh() async {
    try {
      maximized.value =
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen();
    } on Object {
      // No window hooks: the frame stays as it is.
    }
  }

  @override
  void onWindowMaximize() => _refresh();
  @override
  void onWindowUnmaximize() => _refresh();
  @override
  void onWindowEnterFullScreen() => _refresh();
  @override
  void onWindowLeaveFullScreen() => _refresh();
  @override
  void onWindowResized() => _refresh();
  @override
  void onWindowFocus() => focused.value = true;
  @override
  void onWindowBlur() => focused.value = false;
}

/// Rounds the window's corners on Linux while VoxCordis draws its own title
/// bar; GTK draws the shadow and the resize edges around them. Windows 11
/// rounds them itself. Wraps everything, background included.
class WindowCorners extends StatelessWidget {
  const WindowCorners({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isLinux) return child;
    return ListenableBuilder(
      listenable: Listenable.merge([
        TitleBarChoice.system,
        TitleBarChoice.maximized,
      ]),
      builder: (context, child) =>
          TitleBarChoice.system.value || TitleBarChoice.maximized.value
          ? child!
          : ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
      child: child,
    );
  }
}

/// [child] under VoxCordis' title bar, while [TitleBarChoice] says so: a
/// strip to drag the window by (double-click maximises, right-click opens
/// the window menu) with minimise, maximise and close at the right.
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  static const barHeight = 34.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      TitleBarChoice.system,
      TitleBarChoice.maximized,
      TitleBarChoice.focused,
    ]),
    builder: (context, child) {
      if (TitleBarChoice.system.value || !TitleBarChoice.supported) {
        return child!;
      }
      final maximized = TitleBarChoice.maximized.value;
      return Stack(
        children: [
          Column(
            children: [
              _TitleBar(
                maximized: maximized,
                focused: TitleBarChoice.focused.value,
              ),
              Expanded(child: child!),
            ],
          ),
          // Windows keeps its resize edges at the sides and bottom; the top
          // one is this strip.
          if (Platform.isWindows && !maximized)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 4,
              child: DragToResizeArea(
                resizeEdgeSize: 4,
                enableResizeEdges: [ResizeEdge.top],
                child: SizedBox.expand(),
              ),
            ),
        ],
      );
    },
    child: child,
  );
}

class _TitleBar extends StatefulWidget {
  const _TitleBar({required this.maximized, required this.focused});

  final bool maximized;
  final bool focused;

  @override
  State<_TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<_TitleBar> {
  final _maxButton = GlobalKey();

  @override
  void dispose() {
    TitleBarChoice.reportMaxButton(null);
    super.dispose();
  }

  /// Tells Windows where the maximise button landed after this layout.
  void _report(Duration _) {
    if (!mounted) return;
    final box = _maxButton.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ratio = View.of(context).devicePixelRatio;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    TitleBarChoice.reportMaxButton(
      Rect.fromLTRB(
        rect.left * ratio,
        rect.top * ratio,
        rect.right * ratio,
        rect.bottom * ratio,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Rebuilt on every resize, so the spot sent to Windows follows along.
    builder: (context, _) {
      if (Platform.isWindows) {
        WidgetsBinding.instance.addPostFrameCallback(_report);
      }
      return _bar(context);
    },
  );

  Widget _bar(BuildContext context) {
    final maximized = widget.maximized;
    final focused = widget.focused;
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: WindowFrame.barHeight,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: () async => await windowManager.isMaximized()
                    ? windowManager.unmaximize()
                    : windowManager.maximize(),
                onSecondaryTap: windowManager.popUpWindowMenu,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: focused ? 1 : 0.55,
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      Image.asset(
                        'assets/brand/app_icon.png',
                        width: 16,
                        height: 16,
                        filterQuality: FilterQuality.medium,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'VoxCordis',
                        style: TextStyle(
                          fontSize: 12.5,
                          letterSpacing: 0.3,
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _CaptionButton(
              icon: Icons.remove_rounded,
              onTap: windowManager.minimize,
            ),
            _CaptionButton(
              key: _maxButton,
              native: Platform.isWindows ? TitleBarChoice.maxButtonState : null,
              icon: maximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              iconSize: maximized ? 13 : 15,
              onTap: () => maximized
                  ? windowManager.unmaximize()
                  : windowManager.maximize(),
            ),
            // Through the window's own close, so "Close to the system tray"
            // still applies.
            _CaptionButton(
              icon: Icons.close_rounded,
              danger: true,
              onTap: windowManager.close,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconSize = 16,
    this.danger = false,
    this.native,
  });

  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;

  /// Close: red under the pointer.
  final bool danger;

  /// (hover, pressed) as Windows reports it, for the maximise button.
  final ValueListenable<(bool, bool)>? native;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final native = widget.native;
    if (native == null) return _build(context, _hover, _down);
    return ValueListenableBuilder(
      valueListenable: native,
      builder: (context, state, _) =>
          _build(context, _hover || state.$1, _down || state.$2),
    );
  }

  Widget _build(BuildContext context, bool hover, bool down) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final fill = !hover
        ? Colors.transparent
        : widget.danger
        ? const Color(0xFFE5484D).withValues(alpha: down ? 0.75 : 0.9)
        : (down ? accent.withValues(alpha: 0.25) : palette.tile);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTap: () {
          setState(() => _down = false);
          widget.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 40,
          height: 26,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: hover && widget.danger ? Colors.white : palette.text,
          ),
        ),
      ),
    );
  }
}
