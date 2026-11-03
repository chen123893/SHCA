import 'package:firebase_auth/firebase_auth.dart';

abstract interface class PasswordChangeService {
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });
}

class FirebasePasswordChangeService implements PasswordChangeService {
  FirebasePasswordChangeService({FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email?.trim();
    if (user == null || email == null || email.isEmpty) {
      throw const PasswordChangeFailure(
        'Your password cannot be changed right now. Please sign in again.',
      );
    }

    final usesPassword = user.providerData.any(
      (provider) => provider.providerId == EmailAuthProvider.PROVIDER_ID,
    );
    if (!usesPassword) {
      throw const PasswordChangeFailure(
        'This account does not use an email password. Sign in with the same method used to create the account.',
      );
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: email,
        password: currentPassword,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (error) {
      throw PasswordChangeFailure(_messageFor(error.code));
    }
  }

  String _messageFor(String code) {
    switch (code) {
      case 'wrong-password':
      case 'invalid-credential':
        return 'The current password is incorrect.';
      case 'weak-password':
        return 'The new password is too weak.';
      case 'requires-recent-login':
        return 'For security, please log out, sign in again, and retry.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'Could not connect. Check your internet connection and try again.';
      case 'user-disabled':
      case 'user-not-found':
        return 'This account is unavailable. Please sign in again.';
      case 'operation-not-allowed':
        return 'Password changes are unavailable for this account.';
      default:
        return 'Password could not be changed. Please try again.';
    }
  }
}

class PasswordChangeFailure implements Exception {
  const PasswordChangeFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
