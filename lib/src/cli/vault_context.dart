import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../index/reader.dart';
import '../model.dart';
import '../vault/linkgraph.dart';
import '../vault/scanner.dart';

/// A CLI-level failure with an explicit process exit code, thrown by the
/// helpers in this file and caught at the command layer.
class CliError implements Exception {
  final int exitCode;
  final String message;
  const CliError(this.exitCode, this.message);
  @override
  String toString() => message;
}

/// Difference between the vault's current contents and what `.brain/index.bin`
/// was built from.
class StalenessReport {
  final bool stale;
  final int added;
  final int changed;
  final int removed;

  const StalenessReport({
    required this.stale,
    required this.added,
    required this.changed,
    required this.removed,
  });

  int get total => added + changed + removed;

  Map<String, Object?> toJson() => {
        'stale': stale,
        'added': added,
        'changed': changed,
        'removed': removed,
      };
}

/// Resolves the vault root (via `--vault`, else searching upward from the
/// current directory) and loads its config. Throws [CliError] with exit code
/// 3 when no vault is found - every command except `version` needs this.
Future<VaultContext> openVaultContext(String? vaultOption) async {
  const notFound =
      CliError(3, 'no vault found; run `my-brain init` in your vault root');

  final root = vaultOption != null
      ? p.absolute(vaultOption)
      : BrainConfig.findVaultRoot(Directory.current.path);
  if (root == null) throw notFound;
  if (!Directory(p.join(root, brainDirName)).existsSync()) throw notFound;

  return VaultContext(vaultRoot: root, config: BrainConfig.load(root));
}

/// Resolved vault root, config, and (lazily) the shared index reader for one
/// command invocation.
class VaultContext {
  final String vaultRoot;
  final BrainConfig config;

  IndexReader? _reader;

  VaultContext({required this.vaultRoot, required this.config});

  /// Opens (and caches) the index reader. Throws [CliError] with exit code 3
  /// when `.brain/index.bin` is missing or unreadable.
  Future<IndexReader> openIndex() async {
    final cached = _reader;
    if (cached != null) return cached;
    if (!File(config.indexPath).existsSync()) {
      throw const CliError(3, 'no index; run `my-brain index`');
    }
    try {
      final reader = await IndexReader.open(config.indexPath);
      _reader = reader;
      return reader;
    } on Exception catch (e) {
      throw CliError(3, 'no index; run `my-brain index` ($e)');
    }
  }

  /// Compares a fresh scan of the vault against the index's manifest hash,
  /// diffing scanned files against indexed [DocRecord]s by path/mtime/size to
  /// report added/changed/removed counts.
  Future<StalenessReport> checkStaleness() async {
    final reader = await openIndex();
    final manifest = await VaultScanner(config).scan();
    if (_bytesEqual(manifest.hash, reader.manifestHash)) {
      return const StalenessReport(
          stale: false, added: 0, changed: 0, removed: 0);
    }

    final indexed = <String, DocRecord>{
      for (final d in await reader.allDocs()) d.path: d,
    };
    final scanned = {for (final f in manifest.files) f.path: f};

    var added = 0;
    var changed = 0;
    for (final entry in scanned.entries) {
      final prev = indexed[entry.key];
      if (prev == null) {
        added++;
      } else if (prev.mtimeMs != entry.value.mtimeMs ||
          prev.size != entry.value.size) {
        changed++;
      }
    }
    final removed =
        indexed.keys.where((path) => !scanned.containsKey(path)).length;

    return StalenessReport(
        stale: true, added: added, changed: changed, removed: removed);
  }

  /// Resolves a note argument - a vault-relative path, an absolute path
  /// inside the vault, a bare filename with or without `.md`, or a
  /// title/alias - against the index. Throws [CliError] (exit 1) when
  /// nothing matches, or when more than one document could have answered it.
  Future<DocRecord> resolveNote(String arg) async {
    final reader = await openIndex();
    final docs = await reader.allDocs();
    final resolver = LinkResolver(docs);

    var target = arg;
    if (p.isAbsolute(arg)) {
      target = p.relative(arg, from: vaultRoot).replaceAll(r'\', '/');
    }

    final doc = resolver.resolve(target);
    if (doc == null) {
      throw CliError(1, 'no note matches "$arg"');
    }
    if (resolver.isAmbiguous(target)) {
      final candidates = _candidatesFor(docs, target);
      throw CliError(1, 'ambiguous note "$arg": ${candidates.join(', ')}');
    }
    return doc;
  }

  Future<void> close() async {
    final reader = _reader;
    if (reader != null) await reader.close();
  }
}

/// Best-effort listing of every document that could plausibly have answered
/// [target], for an "ambiguous note" error message. Mirrors [LinkResolver]'s
/// match rules (exact path, path+.md, filename stem, title, alias, all
/// case-insensitive) without depending on its internals, which it does not
/// expose.
List<String> _candidatesFor(List<DocRecord> docs, String target) {
  final lower = target.toLowerCase();
  final lowerMd = lower.endsWith('.md') ? lower : '$lower.md';
  final matches = <String>{};
  for (final d in docs) {
    final pathLower = d.path.toLowerCase();
    if (pathLower == lower || pathLower == lowerMd) matches.add(d.path);
    if (p.basenameWithoutExtension(d.path).toLowerCase() == lower) {
      matches.add(d.path);
    }
    if (d.title.toLowerCase() == lower) matches.add(d.path);
    if (d.aliases.any((a) => a.toLowerCase() == lower)) matches.add(d.path);
  }
  return matches.toList()..sort();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
