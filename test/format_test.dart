import 'dart:convert';
import 'dart:typed_data';

import 'package:my_brain/src/index/format.dart';
import 'package:test/test.dart';

void main() {
  group('ByteWriter/ByteCursor varints', () {
    void roundTrip(int value) {
      final w = ByteWriter();
      w.writeVarint(value);
      final bytes = w.takeBytes();
      final cursor = ByteCursor(bytes);
      expect(cursor.readVarint(), value, reason: 'value $value');
      expect(cursor.atEnd, isTrue);
    }

    test('round-trips boundary values', () {
      for (final v in [0, 1, 127, 128, 16383, 16384, 123456789012345]) {
        roundTrip(v);
      }
    });

    test('rejects negative varints', () {
      final w = ByteWriter();
      expect(() => w.writeVarint(-1), throwsArgumentError);
    });

    test('multiple varints in sequence decode in order', () {
      final w = ByteWriter();
      final values = [0, 1, 127, 128, 300, 16383, 16384, 999999];
      for (final v in values) {
        w.writeVarint(v);
      }
      final cursor = ByteCursor(w.takeBytes());
      for (final v in values) {
        expect(cursor.readVarint(), v);
      }
      expect(cursor.atEnd, isTrue);
    });
  });

  group('String and string-list round-trip', () {
    test('round-trips unicode and empty strings', () {
      final w = ByteWriter();
      const strings = ['', 'hello', 'café', '日本語', '🎉emoji', 'a b c'];
      for (final s in strings) {
        w.writeString(s);
      }
      final cursor = ByteCursor(w.takeBytes());
      for (final s in strings) {
        expect(cursor.readString(), s);
      }
      expect(cursor.atEnd, isTrue);
    });

    test('round-trips string lists including empty list', () {
      final w = ByteWriter();
      w.writeStringList(<String>[]);
      w.writeStringList(['one', 'two', '日本語']);
      final cursor = ByteCursor(w.takeBytes());
      expect(cursor.readStringList(), <String>[]);
      expect(cursor.readStringList(), ['one', 'two', '日本語']);
      expect(cursor.atEnd, isTrue);
    });
  });

  group('IndexHeader', () {
    IndexHeader sampleHeader() => IndexHeader(
          formatVersion: indexFormatVersion,
          docCount: 42,
          avgDocLen: 123.456,
          k1: 1.2,
          b: 0.75,
          docLensOffset: 160,
          docOffsOffset: 328,
          docRecsOffset: 664,
          termOffsetsOffset: 5000,
          termEntriesOffset: 5800,
          termCount: 100,
          postingsOffset: 9000,
          attrOffsetsOffset: 12000,
          attrEntriesOffset: 12080,
          attrCount: 10,
          totalPostings: 500,
          manifestHash:
              Uint8List.fromList(List<int>.generate(32, (i) => i * 7 % 256)),
        );

    test('round-trips through bytes', () {
      final header = sampleHeader();
      final bytes = header.toBytes();
      expect(bytes.length, indexHeaderSize);
      final decoded = IndexHeader.fromBytes(bytes);
      expect(decoded.formatVersion, header.formatVersion);
      expect(decoded.docCount, header.docCount);
      expect(decoded.avgDocLen, header.avgDocLen);
      expect(decoded.k1, header.k1);
      expect(decoded.b, header.b);
      expect(decoded.docLensOffset, header.docLensOffset);
      expect(decoded.docOffsOffset, header.docOffsOffset);
      expect(decoded.docRecsOffset, header.docRecsOffset);
      expect(decoded.termOffsetsOffset, header.termOffsetsOffset);
      expect(decoded.termEntriesOffset, header.termEntriesOffset);
      expect(decoded.termCount, header.termCount);
      expect(decoded.postingsOffset, header.postingsOffset);
      expect(decoded.attrOffsetsOffset, header.attrOffsetsOffset);
      expect(decoded.attrEntriesOffset, header.attrEntriesOffset);
      expect(decoded.attrCount, header.attrCount);
      expect(decoded.totalPostings, header.totalPostings);
      expect(decoded.manifestHash, header.manifestHash);
    });

    test('throws IndexFormatException on truncated bytes', () {
      final bytes = Uint8List(10);
      expect(
        () => IndexHeader.fromBytes(bytes),
        throwsA(isA<IndexFormatException>()),
      );
    });

    test('throws IndexFormatException on bad magic', () {
      final bytes = sampleHeader().toBytes();
      bytes[0] = 0;
      expect(
        () => IndexHeader.fromBytes(bytes),
        throwsA(isA<IndexFormatException>()),
      );
    });

    test('throws IndexFormatException on wrong version', () {
      final bytes = sampleHeader().toBytes();
      final d = ByteData.sublistView(bytes);
      d.setUint32(8, indexFormatVersion + 1, Endian.little);
      expect(
        () => IndexHeader.fromBytes(bytes),
        throwsA(
          isA<IndexFormatException>().having(
            (e) => e.toString(),
            'message',
            contains('my-brain index'),
          ),
        ),
      );
    });
  });

  group('compareTermBytes', () {
    test('orders ASCII lexicographically', () {
      expect(compareTermBytes('apple', 'banana'), lessThan(0));
      expect(compareTermBytes('banana', 'apple'), greaterThan(0));
      expect(compareTermBytes('apple', 'apple'), 0);
    });

    test('orders by UTF-8 byte length when one is a prefix of the other', () {
      expect(compareTermBytes('app', 'apple'), lessThan(0));
      expect(compareTermBytes('apple', 'app'), greaterThan(0));
    });

    test('orders non-ASCII terms consistently with encoded UTF-8 bytes', () {
      final terms = ['zebra', 'café', 'apple', '日本語', 'ångström'];
      final sorted = List<String>.of(terms)..sort(compareTermBytes);
      final expected = List<String>.of(terms)
        ..sort((a, b) {
          final ab = utf8.encode(a);
          final bb = utf8.encode(b);
          final n = ab.length < bb.length ? ab.length : bb.length;
          for (var i = 0; i < n; i++) {
            if (ab[i] != bb[i]) return ab[i] - bb[i];
          }
          return ab.length - bb.length;
        });
      expect(sorted, expected);
    });

    test('orders by codepoint, not raw UTF-16 code-unit value', () {
      // U+E000 (BMP private-use) has a single UTF-16 code unit 0xE000.
      // U+10000 (first supplementary-plane codepoint) is encoded as a
      // surrogate pair whose high surrogate is 0xD800 - lower than 0xE000.
      // A naive String.compareTo (UTF-16 code-unit order) would therefore
      // put U+10000 *before* U+E000, which is wrong by codepoint value and
      // by UTF-8 byte order (0xF0... > 0xEE...). compareTermBytes must get
      // this right since it drives binary search over UTF-8-sorted entries.
      final bmpPrivateUse = String.fromCharCode(0xE000);
      final supplementary = String.fromCharCode(0x10000);

      expect(
        bmpPrivateUse.compareTo(supplementary),
        greaterThan(0),
        reason: 'sanity check: raw UTF-16 compareTo is the naive/wrong order',
      );
      expect(compareTermBytes(bmpPrivateUse, supplementary), lessThan(0));
      expect(compareTermBytes(supplementary, bmpPrivateUse), greaterThan(0));
    });
  });
}
