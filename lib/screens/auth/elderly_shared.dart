import 'package:flutter/material.dart';

const Color elderlyPageBackground = Color(0xFFFFF8F0);
const Color elderlyOrange = Color(0xFFFF8128);
const Color elderlyPeach = Color(0xFFFFB980);
const Color elderlyInk = Color(0xFF241D19);
const Color elderlyGreen = Color(0xFF4F9A4B);
const Color elderlyRed = Color(0xFFE93832);

class ElderlyPageHeader extends StatelessWidget {
  const ElderlyPageHeader({super.key, required this.title, this.onProfile});

  final String title;
  final VoidCallback? onProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[Color(0xFFFFC99E), Color(0xFFFFB77D)],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              Semantics(
                button: onProfile != null,
                label: 'Open profile',
                child: InkWell(
                  onTap: onProfile,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E8),
                      shape: BoxShape.circle,
                      border: Border.all(color: elderlyOrange, width: 2),
                    ),
                    child: const Icon(
                      Icons.person_rounded,
                      color: elderlyOrange,
                      size: 31,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 58),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: elderlyInk,
                fontSize: 21,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ElderlyBottomNavigation extends StatelessWidget {
  const ElderlyBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onHome,
    required this.onMedicine,
    required this.onMonitor,
    required this.onProfile,
  });

  final int selectedIndex;
  final VoidCallback onHome;
  final VoidCallback onMedicine;
  final VoidCallback onMonitor;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.home_rounded, 'Home', onHome),
      (Icons.medication_rounded, 'Medicine', onMedicine),
      (Icons.health_and_safety_rounded, 'Monitor', onMonitor),
      (Icons.account_circle_rounded, 'Profile', onProfile),
    ];
    return SafeArea(
      top: false,
      child: Container(
        height: 74,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: elderlyPeach,
          borderRadius: BorderRadius.circular(20),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (var index = 0; index < items.length; index++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: index == selectedIndex,
                  label: items[index].$2,
                  child: InkWell(
                    onTap: items[index].$3,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: index == selectedIndex
                            ? Colors.white
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            items[index].$1,
                            color: index == selectedIndex
                                ? elderlyOrange
                                : Colors.white,
                            size: 27,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            items[index].$2,
                            style: TextStyle(
                              color: index == selectedIndex
                                  ? elderlyOrange
                                  : Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget elderlySectionCard({required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE2DAD4)),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: const Color(0xFF5A3D2C).withValues(alpha: 0.06),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: child,
  );
}
