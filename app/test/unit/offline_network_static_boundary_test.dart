import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all url launches pass through the offline-aware wrapper', () {
    final directImports = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.endsWith('/utils/safe_url_launcher.dart'))
        .where((file) => file.readAsStringSync().contains("package:url_launcher/url_launcher.dart"))
        .map((file) => file.path)
        .toList();
    expect(directImports, isEmpty);
  });

  test('Personal Team plist never enables arbitrary network loads', () {
    final generator = File('scripts/generate_ios_dev_info_plist.sh').readAsStringSync();
    final plist = File('ios/Runner/Info-Dev.plist').readAsStringSync();
    expect(generator, isNot(contains('NSAllowsArbitraryLoads')));
    expect(plist, isNot(contains('NSAllowsArbitraryLoads')));
    expect(generator, contains('NSAllowsLocalNetworking'));
    expect(plist, contains('NSAllowsLocalNetworking'));
  });

  test('native WebViews and map tiles have explicit offline gates', () {
    final guardedFiles = [
      'lib/pages/settings/webview.dart',
      'lib/pages/settings/payment_webview_page.dart',
      'lib/pages/settings/widgets/plans_sheet.dart',
      'lib/pages/apps/app_home_web_page.dart',
      'lib/pages/referral/referral_page.dart',
      'lib/pages/home/widgets/daily_summary_card.dart',
      'lib/pages/conversations/conversation_map_page.dart',
      'lib/pages/settings/daily_summary_detail_page.dart',
    ];
    for (final path in guardedFiles) {
      expect(File(path).readAsStringSync(), contains('OfflineNetworkPolicy.current'), reason: path);
    }
  });

  test('online-only startup work has explicit offline gates', () {
    final guardedFiles = [
      'lib/pages/home/page.dart',
      'lib/widgets/bottom_nav_bar.dart',
      'lib/pages/apps/page.dart',
      'lib/pages/conversations/conversations_page.dart',
      'lib/pages/action_items/action_items_page.dart',
      'lib/providers/phone_call_provider.dart',
      'lib/providers/announcement_provider.dart',
    ];
    for (final path in guardedFiles) {
      final source = File(path).readAsStringSync();
      expect(
        source.contains('OfflineNetworkPolicy.current') || source.contains('Env.isOfflineRuntime'),
        isTrue,
        reason: path,
      );
    }
  });
}
