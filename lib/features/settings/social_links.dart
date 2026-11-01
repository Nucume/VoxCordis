import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';

/// One link in the [SocialLinks] row.
class SocialLink {
  const SocialLink(this.name, this.url, {this.asset, this.icon, this.color});

  final String name;
  final String url;

  /// A brand icon under assets/icons (Simple Icons, CC0).
  final String? asset;

  /// A Material icon, for links with no brand mark.
  final IconData? icon;

  /// The brand colour; null follows the text colour (GitHub and X are
  /// black or white).
  final Color? color;
}

/// Glass icon buttons for the website, GitHub, Discord, Reddit and X, each
/// in its brand colour.
class SocialLinks extends StatelessWidget {
  const SocialLinks({super.key});

  static const links = [
    SocialLink(
      'Website',
      'https://voxcordisai.com',
      icon: Icons.language_rounded,
    ),
    SocialLink(
      'GitHub',
      'https://github.com/Nucume/VoxCordis',
      asset: 'assets/icons/github.svg',
    ),
    SocialLink(
      'Discord',
      'https://discord.gg/hJCzp7tVaT',
      asset: 'assets/icons/discord.svg',
      color: Color(0xFF5865F2),
    ),
    SocialLink(
      'Reddit',
      'https://www.reddit.com/r/VoxCordis/',
      asset: 'assets/icons/reddit.svg',
      color: Color(0xFFFF4500),
    ),
    SocialLink('X', 'https://x.com/VoxCordisAI', asset: 'assets/icons/x.svg'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final l in links) _SocialButton(l)],
    );
  }
}

class _SocialButton extends StatefulWidget {
  const _SocialButton(this.link);
  final SocialLink link;

  @override
  State<_SocialButton> createState() => _SocialButtonState();
}

class _SocialButtonState extends State<_SocialButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l = widget.link;
    final color = l.color ?? p.text;
    final r = BorderRadius.circular(16);
    return Tooltip(
      message: l.name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(l.url)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 52,
            height: 52,
            transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: r,
              color: p.glass,
              border: Border.all(
                color: _hover ? color.withValues(alpha: 0.7) : p.glassBorder,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: p.glassSheen,
              ),
              boxShadow: _hover
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.35),
                        blurRadius: 14,
                        blurStyle: BlurStyle.outer,
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: l.asset != null
                  ? SvgPicture.asset(
                      l.asset!,
                      width: 24,
                      height: 24,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    )
                  : Icon(
                      l.icon,
                      size: 26,
                      color: Theme.of(context).colorScheme.primary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
