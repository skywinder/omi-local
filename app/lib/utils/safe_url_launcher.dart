import 'package:url_launcher/url_launcher.dart' as upstream;

import 'package:omi/utils/offline_network_policy.dart';

export 'package:url_launcher/url_launcher.dart' hide launchUrl;

/// Drop-in policy-aware replacement for url_launcher's top-level function.
/// Offline callers receive `false`; no platform channel is invoked.
Future<bool> launchUrl(
  Uri url, {
  upstream.LaunchMode mode = upstream.LaunchMode.platformDefault,
  upstream.WebViewConfiguration webViewConfiguration = const upstream.WebViewConfiguration(),
  upstream.BrowserConfiguration browserConfiguration = const upstream.BrowserConfiguration(),
  String? webOnlyWindowName,
}) async {
  if (!OfflineNetworkPolicy.current.allowsExternalLaunch) return false;
  return upstream.launchUrl(
    url,
    mode: mode,
    webViewConfiguration: webViewConfiguration,
    browserConfiguration: browserConfiguration,
    webOnlyWindowName: webOnlyWindowName,
  );
}
