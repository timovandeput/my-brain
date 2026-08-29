import 'package:path/path.dart' as p;

import '../model.dart';

/// Resolves wikilink targets to indexed documents.
///
/// Obsidian link targets are ambiguous by design: `[[Deep Work]]` may name a
/// title, an alias, a bare filename, or a full vault-relative path, with or
/// without the `.md` extension, in any case. Resolution tries, in order:
/// exact path, path with `.md` appended, unique filename stem, exact title,
/// exact alias - each case-insensitively. Anything still ambiguous resolves to
/// the lexicographically first candidate, so results stay deterministic.
class LinkResolver {
  final List<DocRecord> _docs;

  final Map<String, DocRecord> _byPath = {};
  final Map<String, List<DocRecord>> _byStem = {};
  final Map<String, List<DocRecord>> _byTitle = {};
  final Map<String, List<DocRecord>> _byAlias = {};

  late final Map<int, List<DocRecord>> _backlinks;
  late final Map<String, List<DocRecord>> _brokenLinks;

  LinkResolver(List<DocRecord> docs) : _docs = docs {
    for (final doc in docs) {
      _byPath[doc.path.toLowerCase().trim()] = doc;

      final stem = p.basenameWithoutExtension(doc.path).toLowerCase().trim();
      _byStem.putIfAbsent(stem, () => []).add(doc);

      final title = doc.title.toLowerCase().trim();
      if (title.isNotEmpty) {
        _byTitle.putIfAbsent(title, () => []).add(doc);
      }

      for (final alias in doc.aliases) {
        final a = alias.toLowerCase().trim();
        if (a.isNotEmpty) {
          _byAlias.putIfAbsent(a, () => []).add(doc);
        }
      }
    }
    _computeLinkCaches();
  }

  /// Candidate documents for a normalised (lowercase, trimmed) target, in
  /// resolution-order priority. Returns null when nothing matches at all.
  List<DocRecord>? _matchCandidates(String norm) {
    final direct = _byPath[norm];
    if (direct != null) return [direct];

    if (!norm.endsWith('.md')) {
      final withMd = _byPath['$norm.md'];
      if (withMd != null) return [withMd];
    }

    final stem = p.basenameWithoutExtension(norm);
    final stemCandidates = _byStem[stem];
    if (stemCandidates != null && stemCandidates.isNotEmpty) {
      return stemCandidates;
    }

    final titleCandidates = _byTitle[norm];
    if (titleCandidates != null && titleCandidates.isNotEmpty) {
      return titleCandidates;
    }

    final aliasCandidates = _byAlias[norm];
    if (aliasCandidates != null && aliasCandidates.isNotEmpty) {
      return aliasCandidates;
    }

    return null;
  }

  /// The document [target] names, or null when nothing matches: a broken link.
  DocRecord? resolve(String target) {
    final norm = target.trim().toLowerCase();
    if (norm.isEmpty) return null; // same-file anchor, not a link elsewhere.
    final candidates = _matchCandidates(norm);
    if (candidates == null || candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;
    final sorted = [...candidates]
      ..sort((DocRecord a, DocRecord b) => a.path.compareTo(b.path));
    return sorted.first;
  }

  /// True when more than one document could have answered [target].
  bool isAmbiguous(String target) {
    final norm = target.trim().toLowerCase();
    if (norm.isEmpty) return false;
    final candidates = _matchCandidates(norm);
    return candidates != null && candidates.length > 1;
  }

  void _computeLinkCaches() {
    final backlinkAccum = <int, List<DocRecord>>{};
    final brokenAccum = <String, List<DocRecord>>{};

    for (final doc in _docs) {
      final seenResolved = <int>{};
      final seenBroken = <String>{};
      for (final link in doc.outLinks) {
        final trimmed = link.trim();
        if (trimmed.isEmpty) continue; // same-file anchor: never broken.
        final resolved = resolve(link);
        if (resolved != null) {
          if (seenResolved.add(resolved.docId)) {
            backlinkAccum.putIfAbsent(resolved.docId, () => []).add(doc);
          }
        } else {
          if (seenBroken.add(trimmed)) {
            brokenAccum.putIfAbsent(trimmed, () => []).add(doc);
          }
        }
      }
    }

    for (final list in backlinkAccum.values) {
      list.sort((DocRecord a, DocRecord b) => a.path.compareTo(b.path));
    }
    for (final list in brokenAccum.values) {
      list.sort((DocRecord a, DocRecord b) => a.path.compareTo(b.path));
    }

    _backlinks = backlinkAccum;
    _brokenLinks = brokenAccum;
  }

  /// Documents whose outgoing links resolve to [doc]: the backlinks.
  List<DocRecord> backlinksTo(DocRecord doc) =>
      _backlinks[doc.docId] ?? const [];

  /// Every link target across the vault that resolves to nothing, mapped to
  /// the documents that contain it.
  Map<String, List<DocRecord>> brokenLinks() => _brokenLinks;
}
