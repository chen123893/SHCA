import 'package:flutter/material.dart';

const Color caregiverPageBackground = Color(0xFFFFF8F0);
const Color caregiverOrange = Color(0xFFFF7518);
const Color caregiverPeach = Color(0xFFFFB87D);
const Color caregiverInk = Color(0xFF2B2521);
const Color caregiverGreen = Color(0xFF279D68);
const Color caregiverRed = Color(0xFFE83C36);
const Color caregiverBorder = Color(0xFFF0D7C4);

class CaregiverElderlySelector extends StatelessWidget {
  const CaregiverElderlySelector({
    super.key,
    required this.people,
    required this.selectedId,
    required this.onChanged,
  });

  final List<({String id, String name})> people;
  final String selectedId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('caregiver-elderly-selector'),
      initialValue: selectedId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Linked elderly person',
        prefixIcon: const Icon(Icons.elderly_rounded, color: caregiverOrange),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: caregiverBorder),
        ),
      ),
      items: [
        for (final person in people)
          DropdownMenuItem<String>(
            value: person.id,
            child: Text(person.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: people.length < 2
          ? null
          : (id) {
              if (id != null && id != selectedId) onChanged(id);
            },
    );
  }
}

class CaregiverBottomNavigation extends StatelessWidget {
  const CaregiverBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onHome,
    required this.onStatus,
    required this.onMedicine,
    required this.onProfile,
    this.onStatistics,
  });

  final int selectedIndex;
  final VoidCallback onHome;
  final VoidCallback onStatus;
  final VoidCallback onMedicine;
  final VoidCallback onProfile;
  final VoidCallback? onStatistics;

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.home_rounded, 'Home', onHome),
      (Icons.badge_rounded, 'Status', onStatus),
      (Icons.medication_rounded, 'Medicine', onMedicine),
      (Icons.account_circle_rounded, 'Profile', onProfile),
      (
        Icons.bar_chart_rounded,
        'Statistics',
        onStatistics ?? () => Navigator.pushNamed(context, '/statistics'),
      ),
    ];
    return SafeArea(
      top: false,
      child: Container(
        height: 74,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: caregiverPeach,
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
                    key: Key('caregiver-nav-${items[index].$2.toLowerCase()}'),
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
                                ? caregiverOrange
                                : Colors.white,
                            size: 27,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            items[index].$2,
                            style: TextStyle(
                              color: index == selectedIndex
                                  ? caregiverOrange
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

class CaregiverPageHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const CaregiverPageHeader({
    super.key,
    required this.title,
    this.onProfile,
    this.showBack = false,
  });

  final String title;
  final VoidCallback? onProfile;
  final bool showBack;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: 64,
      backgroundColor: caregiverPeach,
      centerTitle: true,
      titleSpacing: 0,
      leadingWidth: 64,
      leading: showBack
          ? IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : Padding(
              padding: const EdgeInsets.all(10),
              child: Image.asset('assets/images/logo_simple.png'),
            ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 21,
          fontWeight: FontWeight.w900,
        ),
      ),
      actions: [
        SizedBox(
          width: 64,
          child: onProfile == null
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Caregiver profile',
                  onPressed: onProfile,
                  icon: const CircleAvatar(
                    backgroundColor: Color(0xFFFFE9D8),
                    child: Icon(
                      Icons.volunteer_activism_rounded,
                      color: caregiverOrange,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

void openCaregiverHome(BuildContext context) {
  Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
}

void openCaregiverProfile(BuildContext context) {
  Navigator.pushReplacementNamed(context, '/caregiver-profile');
}
