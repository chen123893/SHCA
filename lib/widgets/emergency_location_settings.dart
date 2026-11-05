import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/services/emergency_location_service.dart';

class EmergencyLocationSettings extends StatefulWidget {
  const EmergencyLocationSettings({super.key});
  @override
  State<EmergencyLocationSettings> createState() =>
      _EmergencyLocationSettingsState();
}

class _EmergencyLocationSettingsState extends State<EmergencyLocationSettings>
    with WidgetsBindingObserver {
  bool? _enabled;
  bool _backgroundAllowed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _apply(Map<String, dynamic>? status) {
    if (!mounted || status == null) return;
    setState(() {
      _enabled = status['enabled'] == true;
      _backgroundAllowed = status['backgroundAllowed'] == true;
    });
  }

  Future<void> _load() async {
    try {
      _apply(
        await EmergencyLocationService.channel.invokeMapMethod<String, dynamic>(
          'status',
        ),
      );
    } on PlatformException {
      // Settings stay hidden on unsupported platforms.
    } on MissingPluginException {
      // Native location sharing is available on Android only.
    }
  }

  Future<void> _toggle(bool enabled) async {
    setState(() => _busy = true);
    try {
      _apply(
        await EmergencyLocationService.channel.invokeMapMethod<String, dynamic>(
          'setEnabled',
          {'enabled': enabled},
        ),
      );
      if (mounted && enabled && _enabled != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Allow location permission to share location in emergency alerts.',
            ),
          ),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not change emergency location sharing.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('emergency-location-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Share location in fall and SOS alerts'),
          subtitle: const Text(
            'Share this phone’s current or last known location with linked caregivers. SMS uses plain coordinates; email and the alert page include Maps links.',
          ),
          value: _enabled!,
          onChanged: _busy ? null : _toggle,
        ),
        if (_enabled! && !_backgroundAllowed) ...[
          const Text(
            'To include location when the phone is locked, open Permissions → Location and choose Allow all the time. Alerts still send if location is unavailable.',
          ),
          TextButton(
            onPressed: () => EmergencyLocationService.channel
                .invokeMethod<void>('openSettings'),
            child: const Text('Open location settings'),
          ),
        ],
      ],
    );
  }
}
