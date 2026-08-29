/// Public API surface of my-brain: vault config, the shared data model, the
/// BM25 index (reader/builder/searcher), the vault types, and the CLI
/// entrypoint.
library;

export 'src/cli/runner.dart' show myBrainVersion, runCli;
export 'src/config.dart';
export 'src/index/bm25.dart';
export 'src/index/builder.dart';
export 'src/index/reader.dart';
export 'src/model.dart';
export 'src/vault/frontmatter.dart';
export 'src/vault/linkgraph.dart';
export 'src/vault/markdown.dart';
export 'src/vault/scanner.dart';
