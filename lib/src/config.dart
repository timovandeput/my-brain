import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Directory inside a vault holding all my-brain state.
const String brainDirName = '.brain';
const String configFileName = 'config.yaml';
const String indexFileName = 'index.bin';

/// Configuration for one vault, loaded from `<vault>/.brain/config.yaml`.
class BrainConfig {
  /// Absolute path to the vault root.
  final String vaultRoot;

  /// Glob-ish exclude patterns, matched against vault-relative `/` paths.
  final List<String> exclude;

  /// File extensions to index, lowercase, including the dot.
  final List<String> extensions;

  /// BM25 term-frequency saturation.
  final double k1;

  /// BM25 length normalisation.
  final double b;

  /// Per-field multipliers applied to term frequency at index time.
  final Map<String, double> fieldWeights;

  /// Notes above this body word count are reported as oversized by `doctor`.
  final int splitThresholdWords;

  /// When non-null, only these frontmatter keys are made filterable.
  final List<String>? filterableFrontmatter;

  const BrainConfig({
    required this.vaultRoot,
    this.exclude = defaultExclude,
    this.extensions = const ['.md', '.markdown'],
    this.k1 = 1.2,
    this.b = 0.75,
    this.fieldWeights = defaultFieldWeights,
    this.splitThresholdWords = 1200,
    this.filterableFrontmatter,
  });

  static const List<String> defaultExclude = [
    '.git/**',
    '.brain/**',
    '.obsidian/**',
    '.agents/**',
    '.claude/**',
    '.trash/**',
    'node_modules/**',
    // The agent's own instructions are not notes. Left in, they outrank real
    // notes on any query about the vault itself, and `similar` matches them
    // against everything because they are long and topic-general.
    'AGENTS.md',
    'CLAUDE.md',
  ];

  static const Map<String, double> defaultFieldWeights = {
    'title': 3.0,
    'alias': 3.0,
    'heading': 2.0,
    'tag': 2.0,
    'body': 1.0,
  };

  String get brainDir => p.join(vaultRoot, brainDirName);
  String get configPath => p.join(brainDir, configFileName);
  String get indexPath => p.join(brainDir, indexFileName);

  double weightFor(String field) => fieldWeights[field] ?? 1.0;

  /// Walks up from [start] looking for a directory containing `.brain/`.
  /// Returns null when no vault is found before the filesystem root.
  static String? findVaultRoot(String start) {
    var dir = Directory(p.absolute(start));
    while (true) {
      if (Directory(p.join(dir.path, brainDirName)).existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Loads config for the vault rooted at [vaultRoot]. Missing or unreadable
  /// keys fall back to defaults, so a hand-trimmed config still works.
  static BrainConfig load(String vaultRoot) {
    final root = p.absolute(vaultRoot);
    final file = File(p.join(root, brainDirName, configFileName));
    if (!file.existsSync()) return BrainConfig(vaultRoot: root);
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) return BrainConfig(vaultRoot: root);

    List<String>? strList(String key) {
      final v = doc[key];
      if (v is! YamlList) return null;
      return v.map((dynamic e) => e.toString()).toList();
    }

    double num1(String key, Map<dynamic, dynamic>? m, double fallback) {
      final v = m?[key];
      return v is num ? v.toDouble() : fallback;
    }

    final bm25 = doc['bm25'];
    final weightsNode = doc['field_weights'];
    final weights = <String, double>{...defaultFieldWeights};
    if (weightsNode is YamlMap) {
      for (final entry in weightsNode.entries) {
        final v = entry.value;
        if (v is num) weights[entry.key.toString()] = v.toDouble();
      }
    }

    final split = doc['split_threshold_words'];

    return BrainConfig(
      vaultRoot: root,
      exclude: strList('exclude') ?? defaultExclude,
      extensions: (strList('extensions') ?? const ['.md', '.markdown'])
          .map((String e) => e.toLowerCase())
          .toList(),
      k1: num1('k1', bm25 is YamlMap ? bm25 : null, 1.2),
      b: num1('b', bm25 is YamlMap ? bm25 : null, 0.75),
      fieldWeights: weights,
      splitThresholdWords: split is int ? split : 1200,
      filterableFrontmatter: strList('filterable_frontmatter'),
    );
  }

  /// Renders the on-disk config file. Kept hand-written rather than emitted by
  /// a YAML serialiser so the comments survive.
  String toYaml() {
    final ex = exclude.map((String e) => '  - "$e"').join('\n');
    final exts = extensions.map((String e) => '"$e"').join(', ');
    final fw = fieldWeights.entries
        .map((MapEntry<String, double> e) => '  ${e.key}: ${e.value}')
        .join('\n');
    final filterable = filterableFrontmatter == null
        ? 'filterable_frontmatter: null  # null = index every scalar/list key'
        : 'filterable_frontmatter: [${filterableFrontmatter!.map((String e) => '"$e"').join(', ')}]';
    return '''
# my-brain vault configuration.
# Paths are relative to the vault root (the directory holding this .brain/).
version: 1

# Files matching these patterns are never indexed.
exclude:
$ex

extensions: [$exts]

# BM25 parameters. k1 controls term-frequency saturation, b length normalisation.
bm25:
  k1: $k1
  b: $b

# Term-frequency multipliers per field, applied when the index is built.
field_weights:
$fw

# `my-brain doctor` reports notes longer than this many body words as
# candidates for splitting into smaller, individually retrievable notes.
split_threshold_words: $splitThresholdWords

# Restrict which frontmatter keys can be used with --filter.
$filterable
''';
  }
}
