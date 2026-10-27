import 'dart:io';

import 'package:path/path.dart' as p;

/// "deb" or "rpm" when a package manager installed this copy of VoxCordis
/// (the package carries a `package-type` file next to the program, see
/// packaging/linux/build-packages.sh), else null. A package manager owns
/// such a copy: it updates it, and it brings its own menu entry.
String? installedPackageType() {
  if (!Platform.isLinux) return null;
  try {
    final marker = File(
      p.join(File(Platform.resolvedExecutable).parent.path, 'package-type'),
    );
    final type = marker.readAsStringSync().trim();
    return type == 'deb' || type == 'rpm' ? type : null;
  } on Object {
    return null;
  }
}
