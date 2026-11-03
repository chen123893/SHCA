import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/watch_bridge.dart';
import 'services/wear_motion_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShcaWatchApp());
}

class ShcaWatchApp extends StatelessWidget {
  const ShcaWatchApp({super.key, this.enableServices = true});
  final bool enableServices;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SHCA Watch',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF7518)),
      scaffoldBackgroundColor: const Color(0xFFFFF8F1),
    ),
    home: WatchHome(enableServices: enableServices),
  );
}

enum WatchSignInMode { choose, phone, manual }

enum WatchPage { home, medicines, dose, emergency, activity }

class WatchHome extends StatefulWidget {
  const WatchHome({super.key, this.enableServices = true});
  final bool enableServices;
  @override
  State<WatchHome> createState() => _WatchHomeState();
}

class _WatchHomeState extends State<WatchHome> with WidgetsBindingObserver {
  static const orange = Color(0xFFFF7518),
      red = Color(0xFFEF3C3C),
      green = Color(0xFF21895E);
  final _motion = WearMotionService();
  final _bridge = WatchBridge();
  final _random = math.Random.secure();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _refreshTimer, _countdownTimer, _responseTimer, _codeExpiryTimer;
  WatchSignInMode _signInMode = WatchSignInMode.choose;
  String _phoneSignInCode = '';
  DateTime? _phoneCodeExpiresAt;
  var _state = const WatchInitialState();
  var _snapshot = const MotionSnapshot();
  var _page = WatchPage.home;
  var _dose = const WatchMedication();
  WatchMedication? _deferredDose;
  bool _refreshing = false,
      _initialized = false,
      _confirmingFall = false,
      _signingIn = false,
      _automaticFall = false,
      _sending = false,
      _medicineBusy = false,
      _monitoringBusy = false;
  int _countdown = 15;
  String _emergencyId = '',
      _emergencyStatus = '',
      _emergencyMessage = '',
      _medicineMessage = '',
      _signInMessage = '';
  String _medicineEventId = '', _lastPublishedLabel = '';
  String _fallPermissionMessage = '';
  DateTime? _createdAt, _lastPublishedAt;
  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.enableServices) return;
    _motion.addListener(_onMotion);
    _events = _bridge.events.listen(_onEvent);
    unawaited(_initialize());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refresh()),
    );
  }

  Future<void> _initialize() async {
    try {
      final value = await _bridge.initialize();
      _applyState(value);
      await _syncMotion();
    } catch (_) {
      // Keep the sign-in page available even when the first network check fails.
    } finally {
      if (mounted) setState(() => _initialized = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enableServices) {
      unawaited(_resumeServices());
    } else if (widget.enableServices &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      // The native foreground service owns screen-off sampling and fall
      // delivery. Release Flutter's listeners to avoid duplicate alerts when
      // Wear OS backgrounds this activity.
      unawaited(_motion.stop());
    }
  }

  Future<void> _resumeServices() async {
    await _syncMotion();
    await _refresh();
  }

  Future<void> _syncMotion() async {
    if (_state.signedIn &&
        _state.monitoringEnabled &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await _motion.start();
    } else {
      await _motion.stop();
    }
    if (mounted) setState(() => _snapshot = _motion.snapshot);
  }

  Future<void> _toggleFallDetection() async {
    if (_monitoringBusy) return;
    setState(() => _monitoringBusy = true);
    try {
      final enabled = !_state.monitoringEnabled;
      // Release Flutter sensors before stopping the native service.
      if (!enabled) await _motion.stop();
      await _bridge.setMonitoringEnabled(enabled);
      await _refresh();
      await _syncMotion();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _fallPermissionMessage =
              error.message ?? 'Could not change fall detection.',
        );
      }
      await _syncMotion();
    } finally {
      if (mounted) setState(() => _monitoringBusy = false);
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || !widget.enableServices) return;
    _refreshing = true;
    try {
      _applyState(await _bridge.refresh());
    } catch (_) {
      // Cached account and medicine data remain usable while offline.
    } finally {
      _refreshing = false;
    }
  }

  void _applyState(WatchInitialState value) {
    if (!mounted) return;
    // Native data-layer events already trigger an immediate refresh. The
    // periodic check is only a connection safety net, so avoid rebuilding the
    // entire circular watch screen when nothing visible changed. Repeated
    // rebuilds made medicine cards appear to flash on some Galaxy watches.
    if (!_sameVisibleState(_state, value)) {
      setState(() => _state = value);
    }
    if (value.emergencyAck != null) _onAck(value.emergencyAck!);
    if (value.launchEvent != null) _onEvent(value.launchEvent!);
  }

  bool _sameVisibleState(WatchInitialState first, WatchInitialState second) {
    if (first.connected != second.connected ||
        first.phoneReady != second.phoneReady ||
        first.signedIn != second.signedIn ||
        first.cloudReady != second.cloudReady ||
        first.fallScreenAllowed != second.fallScreenAllowed ||
        first.monitoringEnabled != second.monitoringEnabled ||
        first.accountName != second.accountName ||
        first.exactAlarms != second.exactAlarms ||
        first.notificationsAllowed != second.notificationsAllowed ||
        first.medications.length != second.medications.length) {
      return false;
    }
    for (var index = 0; index < first.medications.length; index++) {
      final a = first.medications[index];
      final b = second.medications[index];
      if (a.id != b.id ||
          a.occurrenceId != b.occurrenceId ||
          a.name != b.name ||
          a.dose != b.dose ||
          a.instruction != b.instruction ||
          a.scheduledAt != b.scheduledAt ||
          a.remindAt != b.remindAt ||
          a.status != b.status) {
        return false;
      }
    }
    return true;
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'fall_confirmation_resolved':
        _motion.acknowledgePossibleFall();
      case 'phone_sign_in_progress':
        setState(() {
          _signingIn = true;
          _signInMessage = '';
        });
      case 'phone_sign_in_result':
        unawaited(_completePhoneSignIn(event));
      case 'phone_state':
      case 'medication_updated':
      case 'session_updated':
        unawaited(_refresh());
      case 'show_medication':
        final dose = WatchMedication.fromMap(event['medication'] as Map?);
        if (!dose.isAvailable) return;
        if (_page == WatchPage.emergency) {
          _deferredDose = dose;
          return;
        }
        setState(() {
          _dose = dose;
          _medicineMessage = '';
          _page = WatchPage.dose;
        });
      case 'fall_acknowledged':
        if (_automaticFall) _back();
      case 'emergency_ack':
        _onAck(event);
      case 'medication_ack':
        if (event['eventId'] == _medicineEventId) {
          setState(() => _medicineMessage = event['message'] as String? ?? '');
        }
    }
  }

  void _onAck(Map<String, dynamic> event) {
    if (_emergencyId.isEmpty || event['eventId'] != _emergencyId) return;
    final next = event['status'] as String? ?? '';
    final message = event['message'] as String? ?? '';
    if (next == _emergencyStatus && message == _emergencyMessage) return;
    if (next == 'received' &&
        ['recorded', 'completed', 'failed'].contains(_emergencyStatus)) {
      return;
    }
    if (_emergencyStatus == 'completed') return;
    _responseTimer?.cancel();
    setState(() {
      _sending = false;
      _emergencyStatus = next;
      _emergencyMessage = message;
    });
  }

  void _onMotion() {
    if (!mounted || !_state.monitoringEnabled) return;
    final next = _motion.snapshot;
    // Motion inference updates frequently. Only the Activity page displays
    // every result; rebuilding medicine/reminder pages for sensor-only changes
    // made their content visibly flash on the watch.
    if (_page == WatchPage.activity) {
      setState(() => _snapshot = next);
    } else {
      _snapshot = next;
    }
    final now = DateTime.now();
    if (next.state == MotionState.active &&
        next.updatedAt != null &&
        (_lastPublishedLabel != next.label ||
            _lastPublishedAt == null ||
            now.difference(_lastPublishedAt!) >= const Duration(seconds: 5))) {
      _lastPublishedAt = now;
      _lastPublishedLabel = next.label;
      unawaited(
        _bridge.publishStatus(
          label: next.label,
          confidence: next.confidence,
          fallProbability: next.fallProbability,
          possibleFall: next.possibleFall,
          updatedAt: next.updatedAt!,
        ),
      );
    }
    if (next.possibleFall && _page != WatchPage.emergency) _openEmergency(true);
  }

  Future<void> _startPhoneSignIn({bool renew = false}) async {
    if (_signingIn) return;
    setState(() {
      _signingIn = true;
      _signInMessage = '';
    });
    try {
      final value = await _bridge.startPhoneSignIn(renew: renew);
      if (!mounted) return;
      if (value['error'] != null) throw StateError(value['error'] as String);
      final code = value['code'] as String? ?? '';
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (value['expiresAt'] as num).toInt(),
      );
      setState(() {
        _signInMode = WatchSignInMode.phone;
        _phoneSignInCode = code;
        _phoneCodeExpiresAt = expiresAt;
      });
      _codeExpiryTimer?.cancel();
      _codeExpiryTimer = Timer(expiresAt.difference(DateTime.now()), () {
        if (mounted &&
            _signInMode == WatchSignInMode.phone &&
            !_state.signedIn) {
          setState(() => _signInMessage = 'Code expired. Tap New code.');
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _signInMessage =
              'Could not create a code. Try again or use email.',
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _completePhoneSignIn(Map<String, dynamic> event) async {
    if (!mounted) return;
    setState(() {
      _signingIn = false;
      _signInMessage = event['error'] as String? ?? '';
    });
    if (event['success'] == true) {
      _codeExpiryTimer?.cancel();
      await _bridge.cancelPhoneSignIn();
      _passwordController.clear();
      await _refresh();
      await _syncMotion();
    }
  }

  Future<void> _selectSignInMode(WatchSignInMode mode) async {
    if (_signingIn) return;
    _codeExpiryTimer?.cancel();
    try {
      await _bridge.cancelPhoneSignIn();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _signInMode = mode;
        _phoneSignInCode = '';
        _phoneCodeExpiresAt = null;
        _signInMessage = '';
      });
    }
  }

  Future<void> _editCredential(bool password) async {
    if (_signingIn) return;
    final controller = password ? _passwordController : _emailController;
    try {
      final value = await _bridge.editCredential(
        field: password ? 'password' : 'email',
        value: controller.text,
      );
      if (value != null && mounted) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _signInMessage =
              error.message ?? 'Use Connect with phone instead.',
        );
      }
    }
  }

  Future<void> _signIn() async {
    if (_signingIn) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!email.contains('@') || password.length < 6) {
      setState(
        () => _signInMessage = 'Enter your elderly account email and password.',
      );
      return;
    }
    setState(() {
      _signingIn = true;
      _signInMessage = '';
    });
    try {
      final response = await _bridge.signIn(email: email, password: password);
      final error = response['error'] as String?;
      if (error != null && error.isNotEmpty) {
        if (mounted) setState(() => _signInMessage = error);
        return;
      }
      final value = await _bridge.refresh();
      _applyState(value);
      await _syncMotion();
      _passwordController.clear();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _signInMessage = error.message ?? 'Sign-in failed.');
      }
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _signInMessage = 'The watch internet connection timed out.',
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _signOut() async {
    await _motion.stop();
    await _bridge.signOut();
    if (!mounted) return;
    setState(() {
      _state = const WatchInitialState();
      _page = WatchPage.home;
      _signInMessage = '';
      _signInMode = WatchSignInMode.choose;
    });
  }

  Future<void> _confirmPossibleFall() async {
    if (_confirmingFall) return;
    _confirmingFall = true;
    try {
      await _bridge.confirmPossibleFall(_snapshot.fallProbability);
      _motion.acknowledgePossibleFall();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _fallPermissionMessage =
              error.message ?? 'Open SHCA to check fall alert settings.',
        );
      }
    } finally {
      _confirmingFall = false;
    }
  }

  void _openEmergency(bool automatic) {
    if (automatic && widget.enableServices) {
      unawaited(_confirmPossibleFall());
      return;
    }

    _countdownTimer?.cancel();
    _responseTimer?.cancel();
    setState(() {
      _automaticFall = automatic;
      _countdown = 15;
      _createdAt = DateTime.now();
      _emergencyId = _newId();
      _emergencyStatus = '';
      _emergencyMessage = '';
      _sending = false;
      _page = WatchPage.emergency;
    });
    if (!automatic) return;
    if (widget.enableServices) {
      unawaited(_bridge.startFallVibration().catchError((_) {}));
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _page != WatchPage.emergency) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        setState(() => _countdown = 0);
        unawaited(_sendEmergency());
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _sendEmergency() async {
    if (_sending || _emergencyStatus == 'completed') return;
    _countdownTimer?.cancel();
    if (widget.enableServices) {
      unawaited(_bridge.stopVibration().catchError((_) {}));
    }
    setState(() {
      _sending = true;
      _emergencyStatus = 'sending';
      _emergencyMessage = 'Sending directly to your caregiver…';
    });
    try {
      final result = await _bridge.sendEmergency(
        eventId: _emergencyId,
        createdAt: _createdAt!,
        source: _automaticFall ? 'wearable_fall' : 'wearable_sos',
        fallProbability: _snapshot.fallProbability,
      );
      if (!mounted || result['eventId'] != _emergencyId) return;
      if (_emergencyStatus == 'sending') {
        setState(() {
          _emergencyStatus = 'queued';
          _emergencyMessage = 'Secure delivery is in progress…';
          _sending = false;
        });
      }
      _responseTimer = Timer(const Duration(seconds: 20), () {
        if (mounted &&
            ['sending', 'queued', 'received'].contains(_emergencyStatus)) {
          setState(() {
            _sending = false;
            _emergencyMessage = 'Delivery is not confirmed yet. Check watch internet or the paired phone, then retry.';
          });
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _sending = false;
          _emergencyStatus = 'failed';
          _emergencyMessage = error is PlatformException
              ? error.message ?? 'Could not send. Please retry.'
              : 'Phone did not respond. Please retry.';
        });
      }
    }
  }

  Future<void> _medicineAction(String action) async {
    if (_medicineBusy || !_dose.isAvailable) return;
    setState(() {
      _medicineBusy = true;
      _medicineMessage = '';
      _medicineEventId = _newId();
    });
    try {
      await _bridge.medicationAction(
        medication: _dose,
        action: action,
        eventId: _medicineEventId,
      );
      if (!mounted) return;
      setState(() {
        _medicineMessage = action == 'taken'
            ? 'Taken saved on watch. Syncing to phone…'
            : 'Snoozed for 10 minutes. Syncing…';
        _page = WatchPage.medicines;
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(
          () => _medicineMessage = error is PlatformException
              ? error.message ?? 'Please try again.'
              : 'Could not save. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _medicineBusy = false);
    }
  }

  void _back() {
    _countdownTimer?.cancel();
    if (widget.enableServices) {
      unawaited(_bridge.stopVibration().catchError((_) {}));
    }
    if (_page == WatchPage.emergency && _automaticFall) {
      _motion.acknowledgePossibleFall();
    }
    setState(() {
      if (_page == WatchPage.dose) {
        _page = WatchPage.medicines;
      } else {
        _page = WatchPage.home;
      }
      _automaticFall = false;
      if (_deferredDose != null) {
        _dose = _deferredDose!;
        _deferredDose = null;
        _page = WatchPage.dose;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _codeExpiryTimer?.cancel();
    _countdownTimer?.cancel();
    _responseTimer?.cancel();
    if (widget.enableServices) {
      unawaited(_bridge.stopVibration().catchError((_) {}));
    }
    unawaited(_events?.cancel());
    _motion.removeListener(_onMotion);
    _motion.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    unawaited(_bridge.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.enableServices && !_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (widget.enableServices && !_state.signedIn) return _signInPage();
    return PopScope(
      canPop: _page == WatchPage.home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: _page == WatchPage.emergency
            ? const Color(0xFFFFF1EF)
            : null,
        body: SafeArea(
          child: switch (_page) {
            WatchPage.home => _home(),
            WatchPage.medicines => _medicines(),
            WatchPage.dose => _dosePage(),
            WatchPage.emergency => _emergency(),
            WatchPage.activity => _activity(),
          },
        ),
      ),
    );
  }

  Widget _signInPage() => PopScope(
    canPop: _signInMode == WatchSignInMode.choose,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_selectSignInMode(WatchSignInMode.choose));
    },
    child: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, size) => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              size.maxWidth * .14,
              size.maxHeight * .12,
              size.maxWidth * .14,
              size.maxHeight * .15,
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.health_and_safety_rounded,
                  color: orange,
                  size: 32,
                ),
                const Text(
                  'Connect SHCA',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                if (_signInMode == WatchSignInMode.choose) ...[
                  const Text(
                    'Use your phone to sign in. No watch keyboard needed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('watch-connect-phone'),
                    onPressed: _signingIn ? null : _startPhoneSignIn,
                    child: Text(
                      _signingIn ? 'Preparing…' : 'Connect with phone',
                    ),
                  ),
                  TextButton(
                    key: const Key('watch-use-email'),
                    onPressed: _signingIn
                        ? null
                        : () => _selectSignInMode(WatchSignInMode.manual),
                    child: const Text('Use email instead'),
                  ),
                ] else if (_signInMode == WatchSignInMode.phone) ...[
                  Text(
                    _phoneSignInCode,
                    key: const Key('watch-sign-in-code'),
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Phone: open SHCA → Profile → Connect smartwatch. Enter this code.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _signingIn
                        ? 'Signing in…'
                        : _phoneCodeExpiresAt?.isBefore(DateTime.now()) == true
                        ? 'Code expired'
                        : 'Valid for 5 minutes • Keep phone paired',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10),
                  ),
                  TextButton(
                    onPressed: _signingIn
                        ? null
                        : () => _startPhoneSignIn(renew: true),
                    child: const Text('New code'),
                  ),
                  TextButton(
                    onPressed: _signingIn
                        ? null
                        : () => _selectSignInMode(WatchSignInMode.manual),
                    child: const Text('Use email instead'),
                  ),
                ] else ...[
                  const Text('Elderly account', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('watch-email'),
                    controller: _emailController,
                    readOnly: true,
                    showCursor: false,
                    canRequestFocus: false,
                    onTap: () => _editCredential(false),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('watch-password'),
                    controller: _passwordController,
                    readOnly: true,
                    showCursor: false,
                    canRequestFocus: false,
                    onTap: () => _editCredential(true),
                    obscureText: true,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('watch-sign-in'),
                    onPressed: _signingIn ? null : _signIn,
                    child: Text(_signingIn ? 'Connecting…' : 'Sign in'),
                  ),
                  TextButton(
                    onPressed: _signingIn
                        ? null
                        : () => _selectSignInMode(WatchSignInMode.choose),
                    child: const Text('Other sign-in options'),
                  ),
                ],
                if (_signInMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _signInMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: red),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget _home() => LayoutBuilder(
    builder: (context, size) {
      return Stack(
        children: [
          Positioned(
            top: size.maxHeight * .085,
            left: size.maxWidth * .2,
            right: size.maxWidth * .2,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'SHCA',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    _state.cloudReady
                        ? 'Standalone'
                        : _state.phoneReady
                        ? 'Phone linked'
                        : 'Syncing',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      color: _state.cloudReady || _state.phoneReady
                          ? green
                          : const Color(0xFF806E63),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: Semantics(
              button: true,
              label: 'Open emergency SOS',
              child: SizedBox(
                width: size.maxWidth * .43,
                height: size.maxWidth * .43,
                child: FilledButton(
                  key: const Key('home-sos'),
                  onPressed: () => _openEmergency(false),
                  style: FilledButton.styleFrom(
                    backgroundColor: red,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Text(
                    'SOS',
                    style: TextStyle(fontSize: 29, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: size.maxHeight * .12,
            left: size.maxWidth * .20,
            right: size.maxWidth * .20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _shortcut(
                  Icons.directions_walk,
                  'Activity',
                  () => setState(() => _page = WatchPage.activity),
                  const Key('activity-shortcut'),
                ),
                _shortcut(
                  Icons.medication,
                  'Medicine',
                  () => setState(() => _page = WatchPage.medicines),
                  const Key('medicine-shortcut'),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  Widget _shortcut(IconData icon, String text, VoidCallback tap, Key key) =>
      Semantics(
        button: true,
        label: text,
        child: InkWell(
          key: key,
          onTap: tap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 54,
            height: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: orange, size: 22),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _scroll(String title, List<Widget> children) => LayoutBuilder(
    builder: (context, size) => SingleChildScrollView(
      key: ValueKey(_page),
      padding: EdgeInsets.fromLTRB(
        size.maxWidth * .15,
        size.maxHeight * .12,
        size.maxWidth * .15,
        size.maxHeight * .2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: TextButton.icon(
              key: const Key('watch-back'),
              onPressed: _back,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Back'),
              style: TextButton.styleFrom(minimumSize: const Size(70, 44)),
            ),
          ),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );
  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFF3CDB4)),
    ),
    child: child,
  );
  Widget _medicines() {
    final now = DateTime.now();
    final next = upcomingToday(_state.medications, now);
    final due = _state.medications
        .where(
          (m) =>
              m.isToday(now) &&
              m.status != 'taken' &&
              m.remindAt != null &&
              !m.remindAt!.isAfter(now),
        )
        .toList();
    return _scroll('Today’s medicine', [
      if (!_state.cloudReady)
        const Text(
          'Showing saved reminders. Internet sync will retry automatically.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      if (_medicineMessage.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            _medicineMessage,
            style: const TextStyle(fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
      if (next.isEmpty)
        _card(
          const Text('No upcoming doses today.', textAlign: TextAlign.center),
        ),
      for (final m in next)
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _time(m.remindAt!),
                style: const TextStyle(
                  color: orange,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text(
                m.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              Text(m.dose, style: const TextStyle(fontSize: 12)),
              if (m.instruction.isNotEmpty)
                Text(m.instruction, style: const TextStyle(fontSize: 11)),
              if (m.status == 'snoozed')
                const Text(
                  'Snoozed',
                  style: TextStyle(color: orange, fontSize: 11),
                ),
            ],
          ),
        ),
      if (due.isNotEmpty) ...[
        const Text(
          'Due earlier today',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        for (final m in due)
          TextButton(
            onPressed: () => setState(() {
              _dose = m;
              _medicineMessage = '';
              _page = WatchPage.dose;
            }),
            child: Text(
              '${m.name} • ${_time(m.remindAt!)}',
              textAlign: TextAlign.center,
            ),
          ),
      ],
      if (!_state.exactAlarms)
        OutlinedButton(
          onPressed: widget.enableServices
              ? () => unawaited(_bridge.requestAlarmPermission())
              : null,
          child: const Text(
            'Allow on-time alarms',
            textAlign: TextAlign.center,
          ),
        ),
      if (!_state.notificationsAllowed)
        OutlinedButton(
          onPressed: widget.enableServices
              ? () => unawaited(_bridge.requestNotifications())
              : null,
          child: const Text('Allow notifications', textAlign: TextAlign.center),
        ),
      OutlinedButton.icon(
        onPressed: widget.enableServices
            ? () => unawaited(_bridge.testVibration())
            : null,
        icon: const Icon(Icons.vibration, size: 18),
        label: const Text('Test vibration'),
      ),
      TextButton(
        onPressed: widget.enableServices
            ? () => unawaited(_bridge.stopVibration())
            : null,
        child: const Text('Stop vibration'),
      ),
    ]);
  }

  Widget _dosePage() => _scroll('Medicine time', [
    _card(
      Column(
        children: [
          const Icon(Icons.medication, size: 36, color: orange),
          Text(
            _dose.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          Text(
            _dose.dose,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
          Text(
            _dose.instruction,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          if (_dose.scheduledAt != null)
            Text(
              'Scheduled ${_time(_dose.scheduledAt!)}',
              style: const TextStyle(fontSize: 11, color: orange),
            ),
        ],
      ),
    ),
    if (_medicineMessage.isNotEmpty)
      Text(_medicineMessage, textAlign: TextAlign.center),
    FilledButton(
      onPressed: _medicineBusy ? null : () => _medicineAction('taken'),
      style: FilledButton.styleFrom(
        backgroundColor: green,
        minimumSize: const Size(0, 46),
      ),
      child: const Text('Taken'),
    ),
    const SizedBox(height: 5),
    FilledButton(
      onPressed: _medicineBusy ? null : () => _medicineAction('snoozed'),
      style: FilledButton.styleFrom(
        backgroundColor: orange,
        minimumSize: const Size(0, 46),
      ),
      child: const Text('Snooze 10 min'),
    ),
    TextButton(onPressed: _back, child: const Text('Back to medicines')),
  ]);
  Widget _emergency() =>
      _scroll(_automaticFall ? 'Possible fall' : 'Emergency SOS', [
        Text(
          _automaticFall && _emergencyStatus.isEmpty
              ? 'Are you safe? Sends in $_countdown s.'
              : 'Send a help request directly to your caregiver.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (_emergencyMessage.isNotEmpty)
          _card(
            Text(
              _emergencyMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        FilledButton(
          key: const Key('send-alert'),
          onPressed: _sending || _emergencyStatus == 'completed'
              ? null
              : _sendEmergency,
          style: FilledButton.styleFrom(
            backgroundColor: red,
            minimumSize: const Size(0, 48),
          ),
          child: Text(
            _sending
                ? 'Sending…'
                : _emergencyStatus == 'completed'
                ? 'Push accepted'
                : _emergencyStatus.isEmpty
                ? 'Send alert'
                : 'Retry',
          ),
        ),
        const SizedBox(height: 5),
        OutlinedButton(
          onPressed: _back,
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          child: Text(
            _automaticFall && _emergencyStatus.isEmpty
                ? 'I’m safe'
                : _emergencyStatus.isEmpty
                ? 'Cancel'
                : 'Back home',
          ),
        ),
        if (_emergencyStatus.isNotEmpty)
          const Text(
            'Going back does not cancel an SOS already sent.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10),
          ),
      ]);
  Widget _activity() => _scroll('Activity', [
    OutlinedButton.icon(
      key: const Key('watch-fall-detection-toggle'),
      onPressed: widget.enableServices && !_monitoringBusy
          ? _toggleFallDetection
          : null,
      icon: Icon(
        _state.monitoringEnabled
            ? Icons.pause_circle_outline
            : Icons.play_circle_outline,
        size: 18,
      ),
      label: Text(
        _monitoringBusy
            ? 'Please wait…'
            : _state.monitoringEnabled
            ? 'Turn off fall detection'
            : 'Turn on fall detection',
        textAlign: TextAlign.center,
      ),
    ),
    const SizedBox(height: 8),
    if (_state.accountName.isNotEmpty)
      Text(
        _state.accountName,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    _card(
      Column(
        children: [
          const Icon(Icons.directions_walk, color: green, size: 30),
          Text(
            _snapshot.label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          Text(
            _snapshot.message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          if (_snapshot.updatedAt != null)
            Text(
              'Updated ${_time(_snapshot.updatedAt!)}',
              style: const TextStyle(fontSize: 10),
            ),
        ],
      ),
    ),
    const SizedBox(height: 8),
    Text(
      _state.fallScreenAllowed
          ? 'Full-screen fall confirmation is ready'
          : 'Enable fall pop-ups to respond while SHCA is closed',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        color: _state.fallScreenAllowed ? green : orange,
      ),
    ),
    if (!_state.fallScreenAllowed)
      OutlinedButton(
        key: const Key('watch-enable-fall-screen'),
        onPressed: widget.enableServices
            ? () async {
                try {
                  await _bridge.requestFallScreenPermission();
                } on PlatformException catch (error) {
                  if (mounted) {
                    setState(
                      () => _fallPermissionMessage =
                          error.message ??
                          'Allow SHCA to appear on top in watch app settings.',
                    );
                  }
                }
              }
            : null,
        child: const Text('Enable fall pop-ups', textAlign: TextAlign.center),
      ),
    if (_fallPermissionMessage.isNotEmpty)
      Text(
        _fallPermissionMessage,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: red),
      ),
    const Text(
      'Quick wrist movements are checked for a fall pattern before an alert appears.',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 11),
    ),
    const SizedBox(height: 8),
    OutlinedButton.icon(
      key: const Key('watch-sign-out'),
      onPressed: widget.enableServices ? () => unawaited(_signOut()) : null,
      icon: const Icon(Icons.logout_rounded, size: 16),
      label: const Text('Sign out'),
    ),
  ]);
  String _time(DateTime date) =>
      '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
}
