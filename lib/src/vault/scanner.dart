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

  Future<VaultManifest> scan() => throw UnimplementedError();

  /// True when [relativePath] is excluded by config.
  bool isExcluded(String relativePath) => throw UnimplementedError();
}

/// Matches a vault-relative path against one exclude pattern.
///
/// Supports `*` (matches within one segment), `**` (any depth), and `?`.
/// Patterns are anchored at the vault root, and a pattern ending in `/**` also
/// matches the directory itself.
bool matchesGlob(String pattern, String path) => throw UnimplementedError();
