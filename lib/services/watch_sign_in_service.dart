import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class WatchSignInService {
  static const _channel = MethodChannel('com.shca.shca/wearable');
  static const _base = String.fromEnvironment(
    'MEDICATION_IMAGE_API_URL',
    defaultValue:
        'https://shca-medication-images.shca-medication-images.workers.dev',
  );

  Future<void> connect(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw StateError('Enter the six-digit code shown on your watch.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in to the elderly account first.');
    final requests =
        await _channel
            .invokeListMethod<dynamic>('findWatchSignInRequests')
            .timeout(const Duration(seconds: 25)) ??
        [];
    final matches = requests
        .whereType<Map>()
        .where((request) => request['code'] == code)
        .toList();
    if (matches.isEmpty) {
      throw StateError(
        'No connected watch matches this code. Open Connect with phone on the watch, keep it nearby, and check Bluetooth.',
      );
    }
    if (matches.length != 1) {
      throw StateError('Generate a new code on your watch and try again.');
    }
    final request = matches.single;
    final token = await user.getIdToken();
    if (token == null) throw StateError('Please sign in again.');
    final response = await http
        .post(
          Uri.parse(
            '${_base.replaceAll(RegExp(r'/+$'), '')}/v1/watch/sign-in-token',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'nonce': request['nonce']}),
        )
        .timeout(const Duration(seconds: 20));
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200 || value['customToken'] is! String) {
      throw StateError(
        value['error'] as String? ?? 'Watch sign-in could not be prepared.',
      );
    }
    if (FirebaseAuth.instance.currentUser?.uid != user.uid) {
      throw StateError('The phone account changed. Please try again.');
    }
    final result = await _channel
        .invokeMapMethod<String, dynamic>('approveWatchSignIn', {
          'nodeId': request['nodeId'],
          'nonce': request['nonce'],
          'code': code,
          'customToken': value['customToken'],
        })
        .timeout(const Duration(seconds: 85));
    if (result?['success'] != true) {
      throw StateError(
        result?['error'] as String? ?? 'The watch could not confirm sign-in.',
      );
    }
  }
}
