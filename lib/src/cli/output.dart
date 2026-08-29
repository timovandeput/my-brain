import 'dart:convert';
import 'dart:io';

/// Owns every write to stdout/stderr for the CLI.
///
/// Command implementations never touch `stdout`/`stderr` directly (that is
/// what trips `avoid_print`); they go through an [Output] instance instead.
/// This keeps `--json` mode's contract simple to guarantee: stdout carries
/// exactly one JSON document and nothing else, while progress, warnings and
/// errors always go to stderr.
class Output {
  /// Emit machine-readable JSON instead of human-readable text.
  final bool json;

  /// Suppress progress lines and the staleness warning.
  final bool quiet;

  final StringSink _out;
  final StringSink _err;

  /// [out]/[err] default to the real process streams; tests inject a
  /// [StringBuffer] instead so output can be asserted on without touching the
  /// process.
  Output({
    this.json = false,
    this.quiet = false,
    StringSink? out,
    StringSink? err,
  })  : _out = out ?? stdout,
        _err = err ?? stderr;

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  /// Emits a result. In `--json` mode this writes [jsonBody] as pretty JSON to
  /// stdout and [humanRenderer] never runs; otherwise [humanRenderer] runs and
  /// is expected to write human-readable lines via [line].
  void emit(Map<String, Object?> jsonBody, void Function() humanRenderer) {
    if (json) {
      _out.writeln(_encoder.convert(jsonBody));
    } else {
      humanRenderer();
    }
  }

  /// Writes one line of human-readable output to stdout. Only meaningful
  /// inside a [emit] `humanRenderer` callback, since that is the only place
  /// guaranteed not to run in `--json` mode.
  void line(String text) => _out.writeln(text);

  /// A warning to stderr; suppressed by `--quiet`.
  void warn(String message) {
    if (quiet) return;
    _err.writeln(message);
  }

  /// An error to stderr; never suppressed.
  void error(String message) => _err.writeln(message);

  /// A progress update to stderr; suppressed by `--quiet`.
  void progress(String message) {
    if (quiet) return;
    _err.writeln(message);
  }

  /// Prompts on stderr and reads a yes/no answer from stdin. Returns false
  /// when stdin is closed (non-interactive) or the answer isn't `y`/`yes`.
  bool confirm(String prompt) {
    _err.write('$prompt [y/N] ');
    final answer = stdin.readLineSync();
    if (answer == null) return false;
    final normalized = answer.trim().toLowerCase();
    return normalized == 'y' || normalized == 'yes';
  }
}

/// Extracts a snippet of roughly [window] characters from [text], centred on
/// the first occurrence of any of [matchedTerms] (case-insensitive, matched
/// against the raw text - not the analyzed tokens). The window is grown
/// outward to whole-word boundaries, internal whitespace is collapsed to
/// single spaces, and an ellipsis marks whichever side was actually cut.
///
/// Returns null when none of [matchedTerms] occur in [text].
String? extractSnippet(
  String text,
  List<String> matchedTerms, {
  int window = 200,
}) {
  final lower = text.toLowerCase();
  var matchStart = -1;
  var matchEnd = -1;
  for (final term in matchedTerms) {
    if (term.isEmpty) continue;
    final idx = lower.indexOf(term.toLowerCase());
    if (idx == -1) continue;
    if (matchStart == -1 || idx < matchStart) {
      matchStart = idx;
      matchEnd = idx + term.length;
    }
  }
  if (matchStart == -1) return null;

  int start;
  int end;
  if (text.length <= window) {
    start = 0;
    end = text.length;
  } else {
    final center = (matchStart + matchEnd) ~/ 2;
    start = center - window ~/ 2;
    end = start + window;
    if (start < 0) {
      start = 0;
      end = window;
    }
    if (end > text.length) {
      end = text.length;
      start = end - window;
      if (start < 0) start = 0;
    }
  }

  start = _wordStart(text, start);
  end = _wordEnd(text, end);

  final prefix = start > 0 ? '… ' : '';
  final suffix = end < text.length ? ' …' : '';
  final collapsed =
      text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
  return '$prefix$collapsed$suffix';
}

bool _isSpace(String c) => c.trim().isEmpty;

/// Grows [pos] left to the start of the word it falls inside, so the window
/// never begins mid-word.
int _wordStart(String text, int pos) {
  var i = pos;
  while (i > 0 && !_isSpace(text[i - 1])) {
    i--;
  }
  return i;
}

/// Grows [pos] right to the end of the word it falls inside, so the window
/// never ends mid-word.
int _wordEnd(String text, int pos) {
  var i = pos;
  while (i < text.length && !_isSpace(text[i])) {
    i++;
  }
  return i;
}
