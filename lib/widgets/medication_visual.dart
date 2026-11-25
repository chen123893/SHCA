import 'package:flutter/material.dart';
import 'package:shca/services/medication_image_service.dart';
import 'package:shca/services/medication_service.dart';

class MedicationVisual extends StatefulWidget {
  const MedicationVisual({
    super.key,
    required this.medication,
    this.size = 60,
    this.storageService = const MedicationImageStorageService(),
  });

  final MedicationSchedule medication;
  final double size;
  final MedicationImageStorageService storageService;

  // Keep this screen's changing values in its own state object.
  @override
  State<MedicationVisual> createState() => _MedicationVisualState();
}

class _MedicationVisualState extends State<MedicationVisual> {
  Future<MedicationImageRequest>? _requestFuture;

  // Prepare the medicine photo request when the widget first appears.
  @override
  void initState() {
    super.initState();
    _prepareRequest();
  }

  // Reload the photo request when the medicine image changes.
  @override
  void didUpdateWidget(covariant MedicationVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.medication.imageKey != widget.medication.imageKey ||
        oldWidget.medication.elderlyId != widget.medication.elderlyId) {
      _prepareRequest();
    }
  }

  // Prepare an authenticated request if the medicine uses a private photo.
  void _prepareRequest() {
    final medication = widget.medication;
    if (medication.imageKey.isEmpty ||
        medication.elderlyId.isEmpty ||
        !widget.storageService.isConfigured) {
      _requestFuture = null;
      return;
    }
    _requestFuture = widget.storageService.authorisedDownload(
      imageKey: medication.imageKey,
      elderlyId: medication.elderlyId,
    );
  }

  // Show the medicine photo or the matching local medicine image.
  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('medication-image-${widget.medication.id}'),
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        image: true,
        label: '${widget.medication.name} medicine image',
        child: _buildImage(),
      ),
    );
  }

  // Show the medicine photo with its loading and error states.
  Widget _buildImage() {
    final requestFuture = _requestFuture;
    if (requestFuture == null) return _fallbackImage();
    return FutureBuilder<MedicationImageRequest>(
      future: requestFuture,
      builder: (context, snapshot) {
        final request = snapshot.data;
        if (request == null) return _fallbackImage();
        return Image.network(
          request.uri.toString(),
          headers: request.headers,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackImage(),
        );
      },
    );
  }

  // Use the matching medicine-type image if there is no usable photo.
  Widget _fallbackImage() {
    return Padding(
      padding: EdgeInsets.all(widget.size * 0.10),
      child: Image.asset(
        medicineAssetFor(widget.medication),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Icon(
          Icons.local_pharmacy_rounded,
          color: const Color(0xFFF04C23),
          size: widget.size * 0.54,
        ),
      ),
    );
  }
}

// Choose a local image from the medicine's type and description.
String medicineAssetFor(MedicationSchedule medication) {
  final name = medication.name.toLowerCase();
  final category = medication.category.toLowerCase();
  final searchable = '$name $category';

  if (searchable.contains('vitamin') ||
      searchable.contains('calcium') ||
      searchable.contains('supplement')) {
    return 'assets/images/vitamin.png';
  }
  if (searchable.contains('blood pressure') ||
      searchable.contains('metformin')) {
    return 'assets/images/tablet.png';
  }
  if (searchable.contains('syrup') ||
      searchable.contains('liquid') ||
      searchable.contains('solution') ||
      searchable.contains('suspension')) {
    return 'assets/images/liquid.png';
  }
  if (searchable.contains('capsule')) {
    return 'assets/images/capsule.png';
  }

  return switch (medication.visual.toLowerCase()) {
    'vitamin' || 'bottle' => 'assets/images/vitamin.png',
    'liquid' || 'syrup' => 'assets/images/liquid.png',
    'capsule' => 'assets/images/capsule.png',
    _ => 'assets/images/tablet.png',
  };
}
