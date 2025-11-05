import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:logger/logger.dart';

class WebSocketService {
  WebSocketChannel? _channel;
  final _logger = Logger();
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  
  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  bool _isConnected = false;
  
  bool get isConnected => _isConnected;

  void connect(String token) {
    try {
      final uri = Uri.parse('ws://localhost:8443/api/v1/ws?token=$token');
      _channel = WebSocketChannel.connect(uri);
      
      _channel!.stream.listen(
        (message) {
          _isConnected = true;
          _logger.d('WebSocket message received: $message');
          
          try {
            final data = json.decode(message as String) as Map<String, dynamic>;
            _messageController.add(data);
          } catch (e) {
            _logger.e('Failed to parse WebSocket message: $e');
          }
        },
        onError: (error) {
          _logger.e('WebSocket error: $error');
          _isConnected = false;
        },
        onDone: () {
          _logger.i('WebSocket connection closed');
          _isConnected = false;
        },
      );
      
      _logger.i('WebSocket connected');
    } catch (e) {
      _logger.e('Failed to connect WebSocket: $e');
      _isConnected = false;
    }
  }

  void sendMessage(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(json.encode(message));
      _logger.d('WebSocket message sent: $message');
    } else {
      _logger.w('WebSocket not connected, cannot send message');
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _isConnected = false;
    _logger.i('WebSocket disconnected');
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
