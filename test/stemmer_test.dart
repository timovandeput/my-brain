import 'package:my_brain/src/text/stemmer.dart';
import 'package:test/test.dart';

void main() {
  group('porterStem', () {
    test('words of length <= 2 are returned unchanged', () {
      expect(porterStem(''), '');
      expect(porterStem('a'), 'a');
      expect(porterStem('is'), 'is');
      expect(porterStem('ax'), 'ax');
    });

    // Step 1a: plural / -s handling.
    test('step 1a', () {
      expect(porterStem('caresses'), 'caress');
      expect(porterStem('ponies'), 'poni');
      expect(porterStem('ties'), 'ti');
      expect(porterStem('caress'), 'caress');
      expect(porterStem('cats'), 'cat');
    });

    // Step 1b: -eed / -ed / -ing, with the at/bl/iz, double-consonant and
    // cvc fixups. Several of these (agreed, conflated, troubled) are further
    // reduced by step 5a later in the pipeline, which is expected: these are
    // the full end-to-end outputs, not the step-1b-only intermediate.
    test('step 1b', () {
      expect(porterStem('feed'), 'feed');
      expect(porterStem('agreed'), 'agre');
      expect(porterStem('plastered'), 'plaster');
      expect(porterStem('bled'), 'bled');
      expect(porterStem('motoring'), 'motor');
      expect(porterStem('sing'), 'sing');
      expect(porterStem('conflated'), 'conflat');
      expect(porterStem('troubled'), 'troubl');
      expect(porterStem('sized'), 'size');
      expect(porterStem('hopping'), 'hop');
      expect(porterStem('tanned'), 'tan');
      expect(porterStem('falling'), 'fall');
      expect(porterStem('hissing'), 'hiss');
      expect(porterStem('fizzed'), 'fizz');
      expect(porterStem('failing'), 'fail');
      expect(porterStem('filing'), 'file');
    });

    // Step 1c: terminal y -> i, only when a vowel precedes it.
    test('step 1c', () {
      expect(porterStem('happy'), 'happi');
      expect(porterStem('sky'), 'sky');
    });

    // Step 2 (double suffixes) plus whatever steps 3-5 do afterwards, since
    // that is the real, observable output of the algorithm.
    test('step 2 and later', () {
      expect(porterStem('relational'), 'relat');
      expect(porterStem('conditional'), 'condit');
      expect(porterStem('rational'), 'ration');
      expect(porterStem('valenci'), 'valenc');
      expect(porterStem('hesitanci'), 'hesit');
      expect(porterStem('digitizer'), 'digit');
      expect(porterStem('conformabli'), 'conform');
      expect(porterStem('radicalli'), 'radic');
      expect(porterStem('differentli'), 'differ');
      expect(porterStem('vileli'), 'vile');
      expect(porterStem('analogousli'), 'analog');
      expect(porterStem('vietnamization'), 'vietnam');
    });

    // Step 3.
    test('step 3', () {
      expect(porterStem('triplicate'), 'triplic');
      expect(porterStem('formative'), 'form');
      expect(porterStem('hopeful'), 'hope');
      expect(porterStem('goodness'), 'good');
    });

    // Step 4.
    test('step 4', () {
      expect(porterStem('revival'), 'reviv');
      expect(porterStem('adjustment'), 'adjust');
      expect(porterStem('sensitiviti'), 'sensit');
      expect(porterStem('sensibiliti'), 'sensibl');
    });

    // Step 5a/5b.
    test('step 5', () {
      expect(porterStem('probate'), 'probat');
      expect(porterStem('cease'), 'ceas');
      // controlling -> controll (steps 1-4) -> control (step 5b: m>1, ends
      // in a doubled consonant that step 1b did not collapse because the
      // word ends in `l`).
      expect(porterStem('controlling'), 'control');
    });

    test('unrelated short words are left alone', () {
      expect(porterStem('meet'), 'meet');
      expect(porterStem('run'), 'run');
    });
  });
}
