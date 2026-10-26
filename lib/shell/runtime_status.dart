import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../data/settings.dart';
import '../services/runtime/runtime_controller.dart';
import '../theme/app_theme.dart';

/// Shows whether the companion's model is loaded; tap to load it or to retry
/// after an error. [dot] is the small light on the portrait or by the name;
/// otherwise it is the labelled chip in the top bar. A right-click (or a
/// long press) moves it to another place.
class RuntimeStatus extends StatelessWidget {
  const RuntimeStatus({super.key, this.dot = false, this.size = 12});

  final bool dot;

  /// The light's diameter as a dot, without its ring.
  final double size;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final runtime = services.runtime;
    return ListenableBuilder(
      listenable: Listenable.merge([runtime, services.rewriting]),
      builder: (context, _) {
        final rewrite = services.rewriting.value;
        final failed = rewrite?.problem != null;
        final rewriting =
            rewrite != null &&
            !failed &&
            (runtime.state == RuntimeState.ready ||
                runtime.state == RuntimeState.external);
        final color = failed
            ? Colors.amberAccent
            : switch (runtime.state) {
                RuntimeState.ready ||
                RuntimeState.external => Colors.greenAccent,
                RuntimeState.error => Colors.redAccent,
                RuntimeState.idle => context.palette.textMuted,
                _ => Colors.amberAccent,
              };
        final busy =
            runtime.state == RuntimeState.installing ||
            runtime.state == RuntimeState.loading ||
            rewriting;
        final label = rewriting || failed ? rewrite!.label : runtime.statusText;
        final detail = rewriting
            ? 'Rewriting the imported character in '
                  '${services.settings.value.companionName}\'s own words. '
                  'Replies may be slower until it is done.'
            : failed
            ? '${rewrite!.problem}\nThe original is kept. Tap to try again.'
            : runtime.error ??
                  (runtime.state == RuntimeState.ready ||
                          runtime.state == RuntimeState.external
                      ? null
                      : 'Tap to load the model');
        final onTap = busy
            ? null
            : failed
            ? () => services.rewriteIfAsked().ignore()
            : () => runtime.ensureReady(services.settings.value).ignore();
        final edge = dot ? size : 10.0;
        final light = busy
            ? SizedBox(
                width: edge,
                height: edge,
                child: Padding(
                  padding: EdgeInsets.all(dot ? size / 8 : 0),
                  child: CircularProgressIndicator(
                    strokeWidth: dot ? size / 7 : 2,
                    value: runtime.progress,
                    color: color,
                  ),
                ),
              )
            : Container(
                width: dot ? size : 9,
                height: dot ? size : 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              );
        final Widget body;
        if (dot) {
          // A ring in the panel's colour keeps the light readable on any
          // portrait.
          body = Container(
            padding: EdgeInsets.all(size > 16 ? size / 5 : 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.alphaBlend(
                context.palette.glass,
                context.palette.background,
              ),
            ),
            child: light,
          );
        } else {
          body = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                light,
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
              ],
            ),
          );
        }
        return Tooltip(
          message: [
            if (dot) label,
            ?detail,
            'Right-click to move this light.',
          ].join('\n'),
          child: GestureDetector(
            onSecondaryTapUp: (d) => _pickPlace(context, d.globalPosition),
            onLongPressStart: (d) => _pickPlace(context, d.globalPosition),
            child: InkWell(
              customBorder: dot ? const CircleBorder() : null,
              borderRadius: dot ? null : BorderRadius.circular(20),
              onTap: onTap,
              child: body,
            ),
          ),
        );
      },
    );
  }

  static Future<void> _pickPlace(BuildContext context, Offset at) async {
    final store = AppScope.of(context).settings;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<StatusLight>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final p in StatusLight.values)
          CheckedPopupMenuItem(
            value: p,
            checked: store.value.statusLight == p,
            child: Text(placeLabel(p)),
          ),
      ],
    );
    if (picked != null) {
      await store.update(store.value.copyWith(statusLight: picked));
    }
  }

  static String placeLabel(StatusLight p) => switch (p) {
    StatusLight.portrait => 'On the portrait',
    StatusLight.name => 'Next to the name',
    StatusLight.header => 'In the chat\'s top bar',
  };
}
