import 'dart:async';
import 'package:omi/services/auth/local_mac_session.dart';
import 'package:omi/env/env.dart';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as socket_channel_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/offline_network_policy.dart';

enum PureSocketStatus { notConnected, connecting, connected, disconnected }

abstract class IPureSocketListener {
  void onConnected();
  void onMessage(dynamic message);
  void onClosed([int? closeCode]);
  void onError(Object err, StackTrace trace);
}

abstract class IPureSocket {
  PureSocketStatus get status;

  Future<bool> connect();
  Future disconnect();
  Future stop();
  void send(dynamic message);

  void setListener(IPureSocketListener listener);

  void onMessage(dynamic message);
  void onConnected();
  void onClosed();
  void onError(Object err, StackTrace trace);
}

class PureSocketMessage {
  String? raw;
}

typedef SocketHeadersProvider = Future<Map<String, String>> Function();
typedef SocketChannelConnector = WebSocketChannel Function(Uri uri, Map<String, String> headers);

class PureSocket implements IPureSocket {
  WebSocketChannel? _channel;
  WebSocketChannel get channel {
    if (_channel == null) {
      throw Exception('Socket is not connected');
    }
    return _channel!;
  }

  PureSocketStatus _status = PureSocketStatus.notConnected;
  @override
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  String url;
  String get _logUrl => Env.usesLocalTunnel ? Uri.parse(url).path : url;
  final SocketHeadersProvider _headersProvider;
  final Map<String, String> _extraHeaders;
  final SocketChannelConnector _channelConnector;

  PureSocket(this.url,
      {SocketHeadersProvider? headersProvider,
      Map<String, String> extraHeaders = const {},
      SocketChannelConnector? channelConnector})
      : _headersProvider =
            headersProvider ?? (() => buildHeaders(requireAuthCheck: true, url: url, forWebSocket: true)),
        _extraHeaders = Map.unmodifiable(extraHeaders),
        _channelConnector = channelConnector ?? _openChannel;

  static WebSocketChannel _openChannel(Uri uri, Map<String, String> headers) => IOWebSocketChannel.connect(
        uri,
        headers: headers,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 15),
      );

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    try {
      OfflineNetworkPolicy.current.requireAllowed(Uri.parse(url));
    } on OfflineNetworkBlocked catch (error) {
      Logger.debug('[Socket] $error');
      return false;
    }
    Logger.debug("request wss $_logUrl");
    final Map<String, String> headers;
    try {
      headers = {...await _headersProvider(), ..._extraHeaders};
    } on AuthTokenUnavailableException catch (e) {
      Logger.debug('[Socket] Connect blocked before send: ${e.result.runtimeType}');
      _status = PureSocketStatus.notConnected;
      return false;
    }

    var uri = Uri.parse(url);
    // Dart's WebSocket upgrade copies Uri.port into an HTTP(S) URI. WS(S)
    // has no implicit Uri port, so spell it out before that conversion.
    // Keep explicit ports unchanged; the network policy still checks them.
    if (!uri.hasPort && (uri.scheme == 'wss' || uri.scheme == 'ws')) {
      uri = uri.replace(port: uri.scheme == 'wss' ? 443 : 80);
    }
    _channel = _channelConnector(uri, headers);
    if (_channel?.ready == null) {
      return false;
    }

    _status = PureSocketStatus.connecting;
    dynamic err;
    try {
      await channel.ready;
    } on TimeoutException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_timeout',
          {'url': _logUrl, 'error': Env.usesLocalTunnel ? e.runtimeType.toString() : e.toString()});
    } on SocketException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_socket_error',
          {'url': _logUrl, 'error': Env.usesLocalTunnel ? e.runtimeType.toString() : e.toString()});
    } on WebSocketChannelException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_websocket_error',
          {'url': _logUrl, 'error': Env.usesLocalTunnel ? e.runtimeType.toString() : e.toString()});
    }
    if (err != null) {
      if (Env.usesLocalTunnel && LocalMacSession.instance.accessKey != null) {
        final base = Uri.parse(Env.apiBaseUrl!);
        final key = LocalMacSession.instance.accessKey!;
        try {
          await LocalMacSession.probeProfile(base, key);
        } on LocalMacUnauthorized {
          await LocalMacSession.instance.rejectRequest(base, 'Bearer $key');
        } catch (_) {
          // Network failure keeps the paired session for the next connection.
        }
      }
      Logger.debug("[Socket] Connect error: ${Env.usesLocalTunnel ? err.runtimeType : err}");
      _status = PureSocketStatus.notConnected;
      return false;
    }
    _status = PureSocketStatus.connected;
    DebugLogManager.logEvent('pure_socket_connected', {'url': _logUrl});
    onConnected();

    final that = this;

    _channel?.stream.listen(
      (message) {
        if (message == "ping") {
          // Logger.debug(message);
          // Pong frame added manually https://www.rfc-editor.org/rfc/rfc6455#section-5.5.2
          _channel?.sink.add([0x8A, 0x00]);
          return;
        }
        that.onMessage(message);
      },
      onError: (err, trace) {
        that.onError(err, trace);
      },
      onDone: () {
        Logger.debug("onDone with close code: ${_channel?.closeCode}");
        that.onClosed(_channel?.closeCode);
      },
      cancelOnError: true,
    );

    return true;
  }

  @override
  Future disconnect() async {
    DebugLogManager.logEvent('pure_socket_disconnecting', {'url': _logUrl, 'current_status': _status.toString()});
    if (_status == PureSocketStatus.connected) {
      // Warn: should not use await cause dead end by socket closed.
      _channel?.sink.close(socket_channel_status.normalClosure);
    }
    _status = PureSocketStatus.disconnected;
    Logger.debug("[Socket] disconnect");
    onClosed(_channel?.closeCode);
  }

  @override
  Future stop() async {
    DebugLogManager.logEvent('pure_socket_stopping', {'url': _logUrl});
    await disconnect();
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    final closeReason = _getCloseCodeReason(closeCode);
    Logger.debug("Socket closed with code: $closeCode ($closeReason)");

    DebugLogManager.logEvent('pure_socket_closed', {
      'close_code': closeCode ?? -1,
      'close_reason': closeReason,
      'url': _logUrl,
    });

    _listener?.onClosed(closeCode);
  }

  String _getCloseCodeReason(int? code) {
    switch (code) {
      case 1000:
        return 'normal_closure';
      case 1001:
        return 'going_away_os_or_background';
      case 1006:
        return 'abnormal_closure';
      case 1008:
        return 'policy_violation_or_auth_error';
      case 1011:
        return 'server_error';
      case 4001:
        return 'auth_token_refresh_required';
      case 4004:
        return 'auth_relogin_required';
      default:
        return 'unknown';
    }
  }

  @override
  void onError(Object err, StackTrace trace) {
    _status = PureSocketStatus.disconnected;
    Logger.debug("[Socket] Error: ${Env.usesLocalTunnel ? err.runtimeType : err}");

    DebugLogManager.logError(Env.usesLocalTunnel ? err.runtimeType : err, trace, 'pure_socket_error', {'url': _logUrl});

    _listener?.onError(err, trace);
    PlatformManager.instance.crashReporter.reportCrash(err, trace);
  }

  @override
  void onMessage(dynamic message) {
    // Logger.debug("[Socket] Message $message");
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void send(message) {
    _channel?.sink.add(message);
  }
}
