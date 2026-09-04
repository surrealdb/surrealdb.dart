import 'dart:convert';

import 'package:surrealdb/memory.dart';
import 'package:test/test.dart';

Stream<List<int>> _sse(List<String> frames) async* {
  for (final frame in frames) {
    yield utf8.encode(frame);
  }
}

void main() {
  group('parseChatStream', () {
    test('parses JSON data frames', () async {
      final chunks = await parseChatStream(_sse([
        'data: {"delta":"Hello"}\n\n',
        'data: {"delta":" world","done":false}\n\n',
        'data: [DONE]\n\n',
      ])).toList();

      expect(chunks.map((c) => c.delta).toList(), ['Hello', ' world', '']);
      expect(chunks.last.done, isTrue);
    });

    test('stops at the done sentinel', () async {
      final chunks = await parseChatStream(_sse([
        'data: {"delta":"one"}\n\n',
        'data: [DONE]\n\n',
        'data: {"delta":"never"}\n\n',
      ])).toList();

      expect(chunks.length, 2);
    });

    test('skips comment lines and reads trace id', () async {
      final chunks = await parseChatStream(_sse([
        ': keep alive\n\n',
        'data: {"delta":"hi","trace_id":"trace:1"}\n\n',
      ])).toList();

      expect(chunks.single.delta, 'hi');
      expect(chunks.single.traceId, 'trace:1');
    });

    test('handles a frame split across byte chunks', () async {
      final chunks = await parseChatStream(_sse([
        'data: {"delta":"par',
        'tial"}\n\n',
      ])).toList();

      expect(chunks.single.delta, 'partial');
    });
  });
}
