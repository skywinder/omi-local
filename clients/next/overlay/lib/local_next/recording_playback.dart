import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'paired_library.dart';

/// Gives the native player a seekable URL while the pairing owns remote requests.
class RecordingPlayback {
  RecordingPlayback._(this._server, this.uri);

  final HttpServer _server;
  final Uri uri;

  static Future<RecordingPlayback> open(PairedLibrary library, String id) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
    final uri = Uri(scheme: 'http', host: server.address.address, port: server.port, path: '/$token.wav');
    server.listen((request) => unawaited(_serve(library, id, request, uri.path)));
    return RecordingPlayback._(server, uri);
  }

  static Future<void> _serve(PairedLibrary library, String id, HttpRequest request, String path) async {
    final response = request.response;
    var started = false;
    try {
      if (request.uri.path != path || request.uri.hasQuery || !const {'GET', 'HEAD'}.contains(request.method)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final ranges = request.headers[HttpHeaders.rangeHeader];
      if (ranges != null && ranges.length != 1) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      final head = request.method == 'HEAD';
      final range = ranges?.single;
      await library.readPlayback(
        id,
        range: range ?? (head ? 'bytes=0-0' : null),
        read: (audio) async {
          response.statusCode = head && range == null && audio.status == HttpStatus.partialContent
              ? HttpStatus.ok
              : audio.status;
          if (audio.totalLength != null) response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          if (audio.contentRange != null &&
              (range != null || audio.status == HttpStatus.requestedRangeNotSatisfiable)) {
            response.headers.set(HttpHeaders.contentRangeHeader, audio.contentRange!);
          }
          if (audio.status == HttpStatus.requestedRangeNotSatisfiable) return;
          response.headers.contentType = ContentType('audio', 'wav');
          response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
          response.contentLength = head && range == null ? audio.totalLength ?? audio.length : audio.length;
          if (head) return;
          started = true;
          await response.addStream(audio.bytes);
        },
      );
    } catch (_) {
      if (!started) response.statusCode = HttpStatus.badGateway;
    } finally {
      try {
        await response.close();
      } catch (_) {
        // A seek, route close or disconnection can retire a request mid-body.
      }
    }
  }

  Future<void> close() async => _server.close(force: true);
}
