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
  LinkResolver(List<DocRecord> docs) {
    throw UnimplementedError();
  }

  /// The document [target] names, or null when nothing matches: a broken link.
  DocRecord? resolve(String target) => throw UnimplementedError();

  /// True when more than one document could have answered [target].
  bool isAmbiguous(String target) => throw UnimplementedError();

  /// Documents whose outgoing links resolve to [doc]: the backlinks.
  List<DocRecord> backlinksTo(DocRecord doc) => throw UnimplementedError();

  /// Every link target across the vault that resolves to nothing, mapped to
  /// the documents that contain it.
  Map<String, List<DocRecord>> brokenLinks() => throw UnimplementedError();
}
