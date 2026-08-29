import '../config.dart';
import '../model.dart';
import '../text/tokenizer.dart';
import '../vault/scanner.dart';

/// Builds `.brain/index.bin` from a scanned file set.
///
/// Indexing is a full rebuild rather than an incremental merge. Rebuilding a
/// few thousand notes costs seconds and is triggered explicitly by the agent,
/// whereas incremental merging into a seek-optimised file is a large amount of
/// machinery whose failure mode is a silently wrong index.
///
/// The output is written to `<indexPath>.tmp` and renamed into place, so a
/// crash mid-build leaves the previous index intact and a reader never sees a
/// half-written file.
class IndexBuilder {
  final BrainConfig config;
  final Analyzer analyzer;

  const IndexBuilder(this.config, this.analyzer);

  /// Reads every file in [manifest], analyses it, and writes the index.
  ///
  /// [onProgress] is called with the number of documents processed so far, for
  /// the CLI progress line; it may be called on any interval.
  Future<IndexStats> build(
    VaultManifest manifest, {
    void Function(int done, int total)? onProgress,
  }) =>
      throw UnimplementedError();
}
