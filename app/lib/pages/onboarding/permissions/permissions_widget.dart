import 'dart:io';

import 'package:flutter/material.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'package:omi/env/env.dart';
import 'package:omi/providers/onboarding_provider.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/dialog.dart';

class PermissionsWidget extends StatefulWidget {
  final VoidCallback goNext;
  final bool? offlineRuntime;

  const PermissionsWidget({super.key, required this.goNext, this.offlineRuntime});

  bool get isOfflineRuntime => offlineRuntime ?? Env.isOfflineRuntime;

  @override
  State<PermissionsWidget> createState() => _PermissionsWidgetState();
}

class _PermissionsWidgetState extends State<PermissionsWidget> {
  @override
  void initState() {
    super.initState();
    if (widget.isOfflineRuntime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<OnboardingProvider>().setLoading(false);
        widget.goNext();
      });
    }
  }

  Future<void> _continue(OnboardingProvider provider) async {
    if (provider.isLoading) return;
    provider.setLoading(true);
    try {
      if (widget.isOfflineRuntime) {
        widget.goNext();
        return;
      }
      if (Platform.isAndroid && !provider.hasBackgroundPermission) {
        await provider.askForBackgroundPermissions();
      }
      final notification = await Permission.notification.request();
      if (notification.isGranted) {
        provider.updateNotificationPermission(true);
      }
      if (await Permission.location.serviceStatus.isEnabled) {
        final location = await Permission.locationWhenInUse.request();
        provider.updateLocationPermission(location.isGranted);
        if (Platform.isIOS && location.isGranted) {
          await provider.alwaysAllowLocation();
        }
      }
      widget.goNext();
    } catch (error, stack) {
      Logger.debug('Failed to complete onboarding permissions: $error\n$stack');
    } finally {
      provider.setLoading(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<OnboardingProvider>(
      builder: (context, provider, child) {
        return Column(
          children: [
            // Background area - takes remaining space
            Expanded(
              child: Container(), // Just takes up space for background image
            ),

            // Bottom drawer card - wraps content
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(32, 0, 32, MediaQuery.of(context).padding.bottom + 8),
              decoration: const BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(40), topRight: Radius.circular(40)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 32),

                    // Main title
                    Text(
                      context.l10n.grantPermissions,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                        fontFamily: 'Manrope',
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 28),

                    // Permissions checkboxes
                    Column(
                      children: [
                        // Background permission (Android only)
                        if (Platform.isAndroid)
                          _buildPermissionTile(
                            value: provider.hasBackgroundPermission,
                            title: context.l10n.backgroundActivity,
                            subtitle: context.l10n.backgroundActivityDesc,
                            onChanged: (s) async {
                              if (s != null) {
                                if (s) {
                                  await provider.askForBackgroundPermissions();
                                } else {
                                  provider.updateBackgroundPermission(false);
                                }
                              }
                            },
                          ),

                        // Location is intentionally absent from the Personal Team offline overlay.
                        if (!widget.isOfflineRuntime)
                          _buildPermissionTile(
                            value: provider.hasLocationPermission,
                            title: context.l10n.locationAccess,
                            subtitle: context.l10n.locationAccessDesc,
                            onChanged: (s) async {
                              if (s != null) {
                                if (s) {
                                  // Auto-check the box immediately when popup is triggered
                                  provider.updateLocationPermission(true);
                                  var (serviceStatus, permissionStatus) = await provider.askForLocationPermissions();
                                  if (!serviceStatus) {
                                    // Uncheck if service is disabled
                                    provider.updateLocationPermission(false);
                                    showDialog(
                                      context: context,
                                      builder: (ctx) {
                                        return getDialog(
                                          context,
                                          () => Navigator.of(context).pop(),
                                          () => Navigator.of(context).pop(),
                                          context.l10n.locationServiceDisabled,
                                          context.l10n.locationServiceDisabledDesc,
                                          singleButton: true,
                                        );
                                      },
                                    );
                                  } else {
                                    bool wasGranted = permissionStatus.isGranted;
                                    provider.updateLocationPermission(wasGranted);
                                    // iOS-only: chain Always request so background
                                    // location updates work in BGTask windows.
                                    await provider.alwaysAllowLocation();
                                    if (wasGranted) {
                                      provider.updateLocationPermission(true);
                                    }
                                  }
                                } else {
                                  provider.updateLocationPermission(false);
                                }
                              }
                            },
                          ),

                        // Remote-notification onboarding is intentionally absent offline.
                        if (!widget.isOfflineRuntime)
                          _buildPermissionTile(
                            value: provider.hasNotificationPermission,
                            title: context.l10n.notifications,
                            subtitle: context.l10n.notificationsDesc,
                            onChanged: (s) async {
                              if (s != null) {
                                if (s) {
                                  await provider.askForNotificationPermissions();
                                } else {
                                  provider.updateNotificationPermission(false);
                                }
                              }
                            },
                          ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // Continue button
                    provider.isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton(
                              onPressed: () => _continue(provider),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                                elevation: 0,
                              ),
                              child: Text(
                                context.l10n.continueButton,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'Manrope',
                                ),
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPermissionTile({
    required bool value,
    required String title,
    required String subtitle,
    required Function(bool?) onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[700]!, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Manrope',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontFamily: 'Manrope'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Transform.scale(
            scale: 1.2,
            child: Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: Colors.white,
              checkColor: Colors.black,
              side: BorderSide(color: Colors.grey[500]!, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
          ),
        ],
      ),
    );
  }
}
