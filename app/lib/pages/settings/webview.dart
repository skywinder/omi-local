import 'package:flutter/material.dart';

import 'package:webview_flutter/webview_flutter.dart';

import 'package:omi/utils/offline_network_policy.dart';

class PageWebView extends StatefulWidget {
  final String url;
  final String title;

  const PageWebView({super.key, required this.url, required this.title});

  @override
  State<PageWebView> createState() => _PageWebViewState();
}

class _PageWebViewState extends State<PageWebView> {
  WebViewController? webViewController;
  int progress = 0;

  @override
  initState() {
    super.initState();
    if (!OfflineNetworkPolicy.current.allowsExternalLaunch) return;
    webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int p) {
            if (mounted) {
              setState(() {
                progress = p;
              });
            }
          },
          onPageStarted: (String url) {},
          onPageFinished: (String url) {},
          onHttpError: (HttpResponseError error) {},
          onWebResourceError: (WebResourceError error) {},
          onNavigationRequest: (NavigationRequest request) {
            if (request.url != widget.url) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    if (!OfflineNetworkPolicy.current.allowsExternalLaunch) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title), backgroundColor: Theme.of(context).colorScheme.primary),
        backgroundColor: Theme.of(context).colorScheme.primary,
        body: const SizedBox.shrink(),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), backgroundColor: Theme.of(context).colorScheme.primary),
      backgroundColor: Theme.of(context).colorScheme.primary,
      body: progress != 100
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : WebViewWidget(controller: webViewController!),
    );
  }
}
