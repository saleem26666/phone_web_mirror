import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// HTTPS + WebSocket server on the phone.
/// Laptop must open https://phone-ip:port/ (Chrome HTTPS-First closes plain HTTP).
class MirrorServer {
  HttpServer? _https;
  HttpServer? _http;
  final Set<WebSocket> _clients = {};
  final int httpsPort;
  final int httpPort;
  void Function(String msg)? onStatus;

  MirrorServer({this.httpsPort = 8443, this.httpPort = 8080});

  bool get isRunning => _https != null;
  int get clientCount => _clients.length;

  Future<SecurityContext> _securityContext() async {
    final cert = await rootBundle.load('assets/certs/cert.pem');
    final key = await rootBundle.load('assets/certs/key.pem');
    final context = SecurityContext();
    context.useCertificateChainBytes(cert.buffer.asUint8List());
    context.usePrivateKeyBytes(key.buffer.asUint8List());
    return context;
  }

  Future<void> start() async {
    await stop();
    final html = await rootBundle.loadString('assets/viewer/index.html');
    final context = await _securityContext();

    _https = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      httpsPort,
      context,
    );
    _https!.idleTimeout = const Duration(seconds: 120);
    _https!.listen((request) => _handle(request, html));

    // Plain HTTP helper: tells user to use HTTPS (Chrome often lands here first).
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
      _http!.listen((request) async {
        try {
          final host = request.headers.host?.split(':').first ?? 'PHONE_IP';
          final secureUrl = 'https://$host:$httpsPort/';
          final body = '''<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Use HTTPS</title>
<meta http-equiv="refresh" content="0;url=$secureUrl">
</head><body style="font-family:sans-serif;background:#111;color:#eee;padding:24px">
<h2>Open this instead</h2>
<p><a style="color:#7ec8ff;font-size:1.3rem" href="$secureUrl">$secureUrl</a></p>
<p>Chrome may warn about the certificate — click <b>Advanced</b> → <b>Proceed</b>.</p>
</body></html>''';
          final bytes = utf8.encode(body);
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..headers.contentLength = bytes.length
            ..add(bytes);
          await request.response.close();
        } catch (e) {
          onStatus?.call('HTTP helper error: $e');
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      onStatus?.call('HTTP $httpPort busy ($e) — use HTTPS $httpsPort');
    }

    onStatus?.call('Server ready — HTTPS :$httpsPort');
  }

  Future<void> _handle(HttpRequest request, String html) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _clients.add(socket);
        onStatus?.call('Browser connected (${_clients.length})');
        socket.done.then((_) {
          _clients.remove(socket);
          onStatus?.call('Browser disconnected (${_clients.length})');
        });
        return;
      }

      final path = request.uri.path;
      if (path == '/' || path == '/index.html' || path.isEmpty) {
        final bytes = utf8.encode(html);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..headers.contentLength = bytes.length
          ..headers.set('Cache-Control', 'no-store')
          ..add(bytes);
        await request.response.close();
        return;
      }

      if (path == '/health') {
        final bytes = utf8.encode('ok');
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.text
          ..headers.contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
        return;
      }

      final bytes = utf8.encode('Not found');
      request.response
        ..statusCode = 404
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    } catch (e) {
      onStatus?.call('Server error: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void broadcast(Uint8List packet) {
    if (_clients.isEmpty) return;
    for (final c in _clients.toList()) {
      try {
        if (c.readyState == WebSocket.open) {
          c.add(packet);
        }
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();
    await _https?.close(force: true);
    await _http?.close(force: true);
    _https = null;
    _http = null;
  }
}
