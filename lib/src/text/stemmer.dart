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
library;

bool _isConsonant(String w, int i) {
  final c = w[i];
  if (c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u') return false;
  if (c == 'y') {
    if (i == 0) return true;
    return !_isConsonant(w, i - 1);
  }
  return true;
}

/// Measure: the number of consonant-vowel sequences (CVC...) in [w].
int _measure(String w) {
  var i = 0;
  final n = w.length;
  var m = 0;
  // Skip initial consonant sequence.
  while (i < n && _isConsonant(w, i)) {
    i++;
  }
  while (i < n) {
    // Skip vowel sequence.
    while (i < n && !_isConsonant(w, i)) {
      i++;
    }
    if (i >= n) break;
    // Skip consonant sequence.
    while (i < n && _isConsonant(w, i)) {
      i++;
    }
    m++;
  }
  return m;
}

/// True when [w] contains a vowel anywhere in `[0, upTo)`.
bool _containsVowel(String w, int upTo) {
  for (var i = 0; i < upTo; i++) {
    if (!_isConsonant(w, i)) return true;
  }
  return false;
}

bool _endsWithDoubleConsonant(String w) {
  final n = w.length;
  if (n < 2) return false;
  if (w[n - 1] != w[n - 2]) return false;
  return _isConsonant(w, n - 1);
}

/// The "cvc" rule: ends consonant-vowel-consonant, where the final consonant
/// is not w, x or y.
bool _endsCvc(String w) {
  final n = w.length;
  if (n < 3) return false;
  final i = n - 1;
  if (!_isConsonant(w, i)) return false; // last char: consonant
  if (_isConsonant(w, i - 1)) return false; // middle char: vowel
  if (!_isConsonant(w, i - 2)) return false; // first of the three: consonant
  final c = w[i];
  if (c == 'w' || c == 'x' || c == 'y') return false;
  return true;
}

bool _endsWith(String w, String suffix) => w.endsWith(suffix);

/// Replaces the ending of [w] matching [suffix] with [replacement], provided
/// [condition] holds against the stem left after removing the suffix.
String? _tryReplace(
  String w,
  String suffix,
  String replacement,
  bool Function(String stem) condition,
) {
  if (!_endsWith(w, suffix)) return null;
  final stem = w.substring(0, w.length - suffix.length);
  if (!condition(stem)) return null;
  return stem + replacement;
}

bool _mGt0(String stem) => _measure(stem) > 0;
bool _mGt1(String stem) => _measure(stem) > 1;

String _step1a(String w) {
  if (w.endsWith('sses')) {
    return '${w.substring(0, w.length - 4)}ss';
  }
  if (w.endsWith('ies')) {
    return '${w.substring(0, w.length - 3)}i';
  }
  if (w.endsWith('ss')) {
    return w;
  }
  if (w.endsWith('s')) {
    return w.substring(0, w.length - 1);
  }
  return w;
}

String _step1b(String w) {
  String? result;
  if (w.endsWith('eed')) {
    final stem = w.substring(0, w.length - 3);
    if (_mGt0(stem)) return '${stem}ee';
    return w;
  }
  var matched = false;
  if (w.endsWith('ed')) {
    final stem = w.substring(0, w.length - 2);
    if (_containsVowel(stem, stem.length)) {
      result = stem;
      matched = true;
    }
  } else if (w.endsWith('ing')) {
    final stem = w.substring(0, w.length - 3);
    if (_containsVowel(stem, stem.length)) {
      result = stem;
      matched = true;
    }
  }
  if (!matched) return w;
  final r = result!;
  if (r.endsWith('at') || r.endsWith('bl') || r.endsWith('iz')) {
    return '${r}e';
  }
  if (_endsWithDoubleConsonant(r) &&
      !r.endsWith('l') &&
      !r.endsWith('s') &&
      !r.endsWith('z')) {
    return r.substring(0, r.length - 1);
  }
  if (_measure(r) == 1 && _endsCvc(r)) {
    return '${r}e';
  }
  return r;
}

String _step1c(String w) {
  if (w.endsWith('y')) {
    final stem = w.substring(0, w.length - 1);
    if (_containsVowel(stem, stem.length)) {
      return '${stem}i';
    }
  }
  return w;
}

// (suffix, replacement, min-measure-of-stem-required)
const List<List<String>> _step2Suffixes = [
  ['ational', 'ate'],
  ['tional', 'tion'],
  ['enci', 'ence'],
  ['anci', 'ance'],
  ['izer', 'ize'],
  ['abli', 'able'],
  ['alli', 'al'],
  ['entli', 'ent'],
  ['eli', 'e'],
  ['ousli', 'ous'],
  ['ization', 'ize'],
  ['ation', 'ate'],
  ['ator', 'ate'],
  ['alism', 'al'],
  ['iveness', 'ive'],
  ['fulness', 'ful'],
  ['ousness', 'ous'],
  ['aliti', 'al'],
  ['iviti', 'ive'],
  ['biliti', 'ble'],
];

String _step2(String w) {
  for (final pair in _step2Suffixes) {
    final result = _tryReplace(w, pair[0], pair[1], _mGt0);
    if (result != null) return result;
  }
  return w;
}

const List<List<String>> _step3Suffixes = [
  ['icate', 'ic'],
  ['ative', ''],
  ['alize', 'al'],
  ['iciti', 'ic'],
  ['ical', 'ic'],
  ['ful', ''],
  ['ness', ''],
];

String _step3(String w) {
  for (final pair in _step3Suffixes) {
    final result = _tryReplace(w, pair[0], pair[1], _mGt0);
    if (result != null) return result;
  }
  return w;
}

const List<String> _step4SimpleSuffixes = [
  'al',
  'ance',
  'ence',
  'er',
  'ic',
  'able',
  'ible',
  'ant',
  'ement',
  'ment',
  'ent',
  'ism',
  'ate',
  'iti',
  'ous',
  'ive',
  'ize',
];

String _step4(String w) {
  for (final suffix in _step4SimpleSuffixes) {
    final result = _tryReplace(w, suffix, '', _mGt1);
    if (result != null) return result;
  }
  // Special cases: (s)ion, (t)ion.
  if (w.endsWith('sion') || w.endsWith('tion')) {
    final stem = w.substring(0, w.length - 3);
    if (_mGt1(stem)) return stem;
  }
  return w;
}

String _step5a(String w) {
  if (w.endsWith('e')) {
    final stem = w.substring(0, w.length - 1);
    final m = _measure(stem);
    if (m > 1) return stem;
    if (m == 1 && !_endsCvc(stem)) return stem;
  }
  return w;
}

String _step5b(String w) {
  if (_mGt1(w) && w.endsWith('l') && _endsWithDoubleConsonant(w)) {
    return w.substring(0, w.length - 1);
  }
  return w;
}

String porterStem(String word) {
  if (word.length <= 2) return word;
  var w = word;
  w = _step1a(w);
  w = _step1b(w);
  w = _step1c(w);
  w = _step2(w);
  w = _step3(w);
  w = _step4(w);
  w = _step5a(w);
  w = _step5b(w);
  return w;
}
