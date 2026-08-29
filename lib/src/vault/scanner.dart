import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../model.dart';

/// The identity of a scanned file set: which paths existed, and their size and
/// mtime. Hashing it tells us whether the index still matches the vault
/// without reading a single file body.
class VaultManifest {
  final List<ScannedFile> files;

  /// sha256 over the sorted `path size mtime` triples.
  final List<int> hash;

  const VaultManifest({required this.files, required this.hash});
}

/// Walks the vault root, applying [BrainConfig.exclude] and
/// [BrainConfig.extensions].
///
/// Paths in the result are vault-relative with forward slashes on every
/// platform, and the list is sorted by path so the manifest hash is stable.
/// Symlinked directories are not followed: a vault that links to itself must
/// not hang the scan.
class VaultScanner {
  final BrainConfig config;
  const VaultScanner(this.config);

  Future<VaultManifest> scan() async {
    final files = <ScannedFile>[];
    final root = Directory(config.vaultRoot);
    if (await root.exists()) {
      await _walk(root, files);
    }
    files.sort((ScannedFile a, ScannedFile b) => a.path.compareTo(b.path));
    return VaultManifest(files: files, hash: _hashOf(files));
  }

  Future<void> _walk(Directory dir, List<ScannedFile> out) async {
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      final relPath = _relativeSlashPath(entity.path);
      if (entity is Directory) {
        // A symlinked directory is never descended into: a vault that links
        // to itself must not hang the scan. With followLinks: false a
        // symlink normally surfaces as a Link entity rather than a
        // Directory, but the explicit check is kept as a defensive guard.
        if (await FileSystemEntity.isLink(entity.path)) continue;
        if (isExcluded(relPath)) continue;
        await _walk(entity, out);
      } else if (entity is File) {
        if (isExcluded(relPath)) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!config.extensions.contains(ext)) continue;
        final stat = await entity.stat();
        out.add(ScannedFile(
          path: relPath,
          absolutePath: entity.path,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
          size: stat.size,
        ));
      }
      // Link entities (symlinked files or directories) are neither indexed
      // nor descended into.
    }
  }

  String _relativeSlashPath(String absolutePath) {
    final rel = p.relative(absolutePath, from: config.vaultRoot);
    return p.split(rel).join('/');
  }

  /// True when [relativePath] is excluded by config.
  bool isExcluded(String relativePath) {
    for (final pattern in config.exclude) {
      if (matchesGlob(pattern, relativePath)) return true;
    }
    return false;
  }
}

List<int> _hashOf(List<ScannedFile> sortedFiles) {
  final buffer = StringBuffer();
  for (final f in sortedFiles) {
    buffer.write('${f.path} ${f.size} ${f.mtimeMs}\n');
  }
  return sha256.convert(utf8.encode(buffer.toString())).bytes;
}

/// Matches a vault-relative path against one exclude pattern.
///
/// Supports `*` (matches within one segment), `**` (any depth), and `?`.
/// Patterns are anchored at the vault root, and a pattern ending in `/**` also
/// matches the directory itself.
bool matchesGlob(String pattern, String path) {
  if (_globToRegExp(pattern).hasMatch(path)) return true;
  if (pattern.endsWith('/**')) {
    final dirPattern = pattern.substring(0, pattern.length - 3);
    if (_globToRegExp(dirPattern).hasMatch(path)) return true;
  }
  return false;
}

RegExp _globToRegExp(String pattern) {
  final sb = StringBuffer(r'^');
  var i = 0;
  final n = pattern.length;
  while (i < n) {
    if (pattern.startsWith('**/', i)) {
      sb.write('(?:[^/]*/)*');
      i += 3;
      continue;
    }
    if (pattern.startsWith('**', i)) {
      sb.write('.*');
      i += 2;
      continue;
    }
    final c = pattern[i];
    if (c == '*') {
      sb.write('[^/]*');
    } else if (c == '?') {
      sb.write('[^/]');
    } else {
      sb.write(RegExp.escape(c));
    }
    i++;
  }
  sb.write(r'$');
  return RegExp(sb.toString());
}
