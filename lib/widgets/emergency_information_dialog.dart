import 'package:flutter/material.dart';

/// Saved profile details for someone assisting the elderly person after SOS.
class EmergencyInformationDialog extends StatefulWidget {
  const EmergencyInformationDialog({
    super.key,
    required this.personName,
    required this.medicalCondition,
    required this.emergencyPhone,
    required this.deliveryTitle,
    required this.deliveryMessage,
    this.onCall,
  });

  final String personName;
  final String medicalCondition;
  final String emergencyPhone;
  final String deliveryTitle;
  final String deliveryMessage;
  final Future<bool> Function()? onCall;

  @override
  State<EmergencyInformationDialog> createState() =>
      _EmergencyInformationDialogState();
}

class _EmergencyInformationDialogState
    extends State<EmergencyInformationDialog> {
  bool _openingDialler = false;
  bool _callFailed = false;

  Future<void> _call() async {
    if (_openingDialler || widget.onCall == null) return;
    setState(() {
      _openingDialler = true;
      _callFailed = false;
    });
    var opened = false;
    try {
      opened = await widget.onCall!();
    } catch (_) {
      // Keep the saved number available even if this device cannot dial.
    }
    if (!mounted) return;
    setState(() {
      _openingDialler = false;
      _callFailed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = widget.emergencyPhone.trim();
    final condition = widget.medicalCondition.trim();
    final name = widget.personName.trim();
    return AlertDialog(
      scrollable: true,
      icon: const Icon(
        Icons.medical_information_outlined,
        color: Color(0xFFE93832),
        size: 44,
      ),
      title: const Text('Emergency information'),
      content: SizedBox(
        width: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Please help this person. Contact their emergency contact below.',
            ),
            const SizedBox(height: 18),
            Text('Name', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(
              name.isEmpty ? 'Name not provided' : name,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 18),
            Text('Medical conditions', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(
              condition.isEmpty
                  ? 'Not provided in the saved profile'
                  : condition,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'As recorded in the saved profile.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Emergency contact', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SelectableText(
                    phone.isEmpty ? 'No number saved' : phone,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (phone.isNotEmpty && widget.onCall != null) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('emergency-contact-call'),
                      onPressed: _openingDialler ? null : _call,
                      icon: const Icon(Icons.call),
                      label: Text(
                        _openingDialler
                            ? 'Opening dialler…'
                            : 'Call emergency contact',
                      ),
                    ),
                  ],
                  if (_callFailed) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Could not open the dialler. Call the number above using another phone.',
                      style: TextStyle(color: Color(0xFFB3261E)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Caregiver notification status'),
              subtitle: Text(widget.deliveryTitle),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(widget.deliveryMessage),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
