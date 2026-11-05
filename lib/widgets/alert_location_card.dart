import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shca/services/emergency_location_service.dart';

class AlertLocationCard extends StatelessWidget {
  const AlertLocationCard({super.key, required this.location});
  final Object? location;

  @override
  Widget build(BuildContext context) {
    final saved = AlertLocation.parse(location);
    if (saved == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Location unavailable for this alert.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }
    final localTime = MaterialLocalizations.of(context);
    final recorded = saved.recordedAt.toLocal();
    final date = localTime.formatMediumDate(recorded);
    final time = localTime.formatTimeOfDay(TimeOfDay.fromDateTime(recorded));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            saved.lastKnown ? 'Last known location' : 'Recorded location',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('From the ${saved.source} · $date, $time'),
          Text(
            'Accuracy about ${saved.accuracyMeters.round()} m',
            style: const TextStyle(color: Colors.black54),
          ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.location_on_outlined),
              label: const Text('Open in Maps'),
              onPressed: () async {
                var opened = false;
                try {
                  opened = await launchUrl(
                    saved.mapsUri,
                    mode: LaunchMode.externalApplication,
                  );
                } catch (_) {
                  // A device without a Maps/browser handler shows the message below.
                }
                if (!context.mounted || opened) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not open Maps. Please try again.'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
