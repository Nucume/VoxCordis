import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../services/folder_service.dart';
import '../../services/invoke_client.dart';
import '../../theme/app_theme.dart';

/// v1 shell: shows Invoke's connection status and the pictures already in
/// `<companion folder>/images/`. Generation arrives with the Invoke adapter.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  Future<String?>? _invokeVersion;
  Future<List<File>>? _images;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context).settings.value;
    _invokeVersion ??= InvokeClient(s.invokeUrl).ping();
    _images ??= _listImages(s.companionFolder);
  }

  static Future<List<File>> _listImages(String? root) async {
    if (root == null) return const [];
    final dir = CompanionFolder(root).images;
    if (!await dir.exists()) return const [];
    final files = await dir
        .list()
        .where(
          (e) =>
              e is File &&
              RegExp(
                r'\.(png|jpe?g|webp)$',
                caseSensitive: false,
              ).hasMatch(e.path),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<String?>(
            future: _invokeVersion,
            builder: (context, snap) {
              final ok = snap.data != null;
              return Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 10,
                    color: snap.connectionState != ConnectionState.done
                        ? context.palette.textMuted
                        : ok
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    snap.connectionState != ConnectionState.done
                        ? 'Looking for Invoke…'
                        : ok
                        ? 'Invoke connected'
                        : 'Invoke not reachable. Check the URL in Settings.',
                    style: TextStyle(color: context.palette.textMuted),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<File>>(
              future: _images,
              builder: (context, snap) {
                final files = snap.data ?? const [];
                if (files.isEmpty) {
                  return Center(
                    child: Text(
                      'No pictures yet.',
                      style: TextStyle(color: context.palette.textMuted),
                    ),
                  );
                }
                return GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: files.length,
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(
                      files[i],
                      fit: BoxFit.cover,
                      cacheWidth: 440,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
