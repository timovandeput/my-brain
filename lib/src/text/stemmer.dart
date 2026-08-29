/// Reduces an English word to its stem, so `meetings`, `meeting` and `meet`
/// all index as one term.
///
/// Implements the Porter algorithm (Porter, 1980). It is deliberately
/// self-contained: the executable ships as a single binary with no data files,
/// and a stemmer is small enough not to justify a dependency.
///
/// The input must already be lowercased and stripped of punctuation; the
/// tokenizer guarantees that. Words of two characters or fewer are returned
/// unchanged.
String porterStem(String word) => throw UnimplementedError();
