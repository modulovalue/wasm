// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('js')
import 'package:test/test.dart';
import 'package:wasm/src/engines/jswasm/bindings.dart';

void main() {
  test('Create and grow', () {
    final memory = Memory(initial: 42);
    expect(memory.lengthInPages, 42);
    expect(memory.lengthInBytes, 2752512);
    expect(memory.grow(10), 42);
    expect(memory.lengthInPages, 52);
    expect(memory.lengthInBytes, 3407872);
  });
  test('Create with maximum and grow', () {
    final memory = Memory(initial: 42, maximum: 52);
    expect(memory.grow(10), 42);
    expect(memory.lengthInPages, 52);
  });
  test(
    'Create shared with maximum and grow',
    () {
      final memory = Memory.shared(initial: 42, maximum: 52);
      expect(memory.grow(10), 42);
      expect(memory.lengthInPages, 52);
    },
    testOn: '!safari',
  );
  test('Create with maximum and grow beyond', () {
    final memory = Memory(initial: 42, maximum: 43);
    expect(
      () {
        memory.grow(2);
      },
      throwsA(isA<ArgumentError>()),
    );
  });
  test(
    'Create shared with maximum and grow beyond',
    () {
      final memory = Memory.shared(initial: 42, maximum: 43);
      expect(
        () {
          memory.grow(2);
        },
        throwsA(isA<ArgumentError>()),
      );
    },
    testOn: '!safari',
  );
  assert(
    () {
      test('Create with invalid size', () {
        expect(() => Memory(initial: -1), throwsA(isA<AssertionError>()));
        expect(
          () => Memory(initial: 42, maximum: 1),
          throwsA(isA<AssertionError>()),
        );
      });
      test(
        'Create shared with invalid size',
        () {
          expect(
            () => Memory.shared(initial: 42, maximum: 1),
            throwsA(isA<AssertionError>()),
          );
        },
        testOn: '!safari',
      );
      return true;
    }(),
  );
}
