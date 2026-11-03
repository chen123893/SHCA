import 'package:flutter/material.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:url_launcher/url_launcher.dart';

class KnowledgeScreen extends StatelessWidget {
  const KnowledgeScreen({super.key});

  static const _topics = <(IconData, String, String, List<String>)>[
    (
      Icons.home_outlined,
      'A safer home',
      'Small changes to everyday spaces',
      [
        'Keep walkways clear of loose rugs, cables and clutter.',
        'Use bright lighting, especially around stairs and on the way to the bathroom.',
        'Fit grab bars in the bathroom and secure handrails along stairs.',
      ],
    ),
    (
      Icons.balance_rounded,
      'Strength and balance',
      'Move with confidence',
      [
        'Regular activities that strengthen your legs and improve balance can help reduce falls.',
        'Ask a health professional which activities are suitable for your ability. Tai chi is one example.',
      ],
    ),
    (
      Icons.visibility_outlined,
      'Eyesight and medicines',
      'Include these in your next check-up',
      [
        'Keep your eyesight checks and glasses prescription up to date.',
        'Ask your doctor or pharmacist to review medicines that may make you dizzy or sleepy. Do not change them on your own.',
        'Tell your healthcare professional about a recent fall or concerns about balance.',
      ],
    ),
    (
      Icons.watch_outlined,
      'Know your monitoring',
      'Understand what SHCA records',
      [
        'A possible-fall alert is a sensor observation, not confirmation of a fall.',
        'Keep your phone or watch charged and check its connection and monitoring status.',
        'Missing records do not mean you were inactive or that no fall happened. SHCA cannot guarantee that every fall is detected.',
        'If you need help, use your emergency contact. Do not wait for a chart or AI report.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: elderlyPageBackground,
    appBar: AppBar(
      title: const Text('Knowledge & prevention'),
      backgroundColor: elderlyPeach,
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        elderlySectionCard(
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.menu_book_rounded, color: elderlyOrange, size: 38),
              SizedBox(height: 12),
              Text(
                'Small steps. Safer days.',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 8),
              Text(
                'Practical knowledge to help you and the people you care for prevent falls.',
                style: TextStyle(fontSize: 16, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (final topic in _topics)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              color: Colors.white,
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: Icon(topic.$1, color: elderlyOrange),
                title: Text(
                  topic.$2,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(topic.$3),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  for (final tip in topic.$4)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        '• $tip',
                        style: const TextStyle(fontSize: 16, height: 1.5),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'General education only. A healthcare professional can help assess your individual needs.',
          style: TextStyle(color: Color(0xFF746A64), height: 1.5),
        ),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Source: CDC fall prevention'),
          onPressed: () async {
            try {
              final opened = await launchUrl(
                Uri.parse('https://www.cdc.gov/falls/prevention/index.html'),
                mode: LaunchMode.externalApplication,
              );
              if (!opened && context.mounted) _sourceError(context);
            } catch (_) {
              if (context.mounted) _sourceError(context);
            }
          },
        ),
        const Text(
          'Monitoring tips describe SHCA behaviour. Prevention content is adapted from the CDC.',
          style: TextStyle(fontSize: 12, color: Color(0xFF746A64)),
        ),
      ],
    ),
  );

  static void _sourceError(BuildContext context) =>
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the source. Please try again.'),
        ),
      );
}
