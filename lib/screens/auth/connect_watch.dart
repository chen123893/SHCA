import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shca/services/watch_sign_in_service.dart';

class ConnectWatchScreen extends StatefulWidget {
  const ConnectWatchScreen({
    super.key,
    required this.accountName,
    this.connect,
  });
  final String accountName;
  final Future<void> Function(String code)? connect;

  @override
  State<ConnectWatchScreen> createState() => _ConnectWatchScreenState();
}

class _ConnectWatchScreenState extends State<ConnectWatchScreen> {
  final _code = TextEditingController();
  bool _busy = false, _done = false;
  String? _error;

  Future<void> _connect() async {
    if (_busy) return;
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter all six digits shown on the watch.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.connect ?? WatchSignInService().connect)(code);
      if (mounted) setState(() => _done = true);
    } catch (error) {
      final message = switch (error) {
        StateError() => error.message,
        PlatformException() => error.message ?? 'Could not reach the watch.',
        TimeoutException() =>
          'The watch did not respond. Check its screen before retrying.',
        _ =>
          'Could not connect the watch. Check both devices have internet and try again.',
      };
      if (mounted) setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Connect smartwatch'),
      backgroundColor: const Color(0xFFFFBC80),
    ),
    backgroundColor: const Color(0xFFFFF8F0),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            _done ? Icons.check_circle : Icons.watch_rounded,
            color: _done ? Colors.green : const Color(0xFFFF8128),
            size: 64,
          ),
          const SizedBox(height: 20),
          Text(
            _done ? 'Watch connected' : 'Sign in on your watch',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            _done
                ? 'Your watch is signed in as ${widget.accountName}. It can now sync directly over its own internet connection.'
                : 'On your watch, open SHCA → Connect with phone. Enter its six-digit code below. Keep your watch paired with this phone through Bluetooth during setup.',
          ),
          const SizedBox(height: 20),
          if (!_done) ...[
            Text(
              'Watch account: ${widget.accountName}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('watch-connection-code'),
              controller: _code,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _connect(),
              decoration: const InputDecoration(
                labelText: 'Six-digit watch code',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 26, letterSpacing: 5),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
              ),
            FilledButton.icon(
              key: const Key('approve-watch-sign-in'),
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(_busy ? 'Waiting for watch…' : 'Connect watch'),
            ),
          ] else
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
        ],
      ),
    ),
  );
}
