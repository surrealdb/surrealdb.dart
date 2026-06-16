// ignore_for_file: avoid_print
// Talks to a Spectron memory service. Set the endpoint, context, and API key
// for your deployment, then:
//   dart run example/spectron_example.dart
import 'package:surrealdb/spectron.dart';

Future<void> main() async {
  final client = Spectron(
    endpoint: 'https://memory.example.com',
    context: 'acme-prod',
    apiKey: 'sp-your-key',
  );

  // Store a memory, scoped to a user.
  await client.remember('I was promoted to CTO', scopes: 'user/tobie');

  // Store a conversation as a batch.
  await client.rememberMany([
    const BatchMessage(role: TurnRole.user, content: 'I moved to Lisbon'),
    const BatchMessage(role: TurnRole.assistant, content: 'Noted.'),
  ]);

  // Recall matching memories.
  final hits = await client.recall("What is Tobie's role?", k: 10);
  print('hits: ${hits['hits']}');

  // Stream a chat reply.
  await for (final chunk in client.chatStream('Summarise what you know')) {
    if (chunk.delta.isNotEmpty) {
      print(chunk.delta);
    }
  }

  client.close();
}
