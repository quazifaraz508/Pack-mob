import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const OcrScreen(),
    );
  }
}

class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key});

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  XFile? _image;
  String _recognizedText = "No text recognized yet.";
  bool _isRecognizing = false;
  String _apiUrl = kIsWeb ? "http://127.0.0.1:8000/api/ocr/" : "http://10.0.2.2:8000/api/ocr/";

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUrl = prefs.getString('api_url') ?? (kIsWeb ? "http://127.0.0.1:8000/api/ocr/" : "http://10.0.2.2:8000/api/ocr/");
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final pickedFile = await _picker.pickImage(source: source);
    if (pickedFile != null) {
      setState(() {
        _image = pickedFile;
        _recognizedText = "Uploading and processing image...\nThis may take a few seconds.";
        _isRecognizing = true;
      });
      await _processImageOnBackend(_image!);
    }
  }

  WebSocketChannel? _channel;

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  Future<void> _processImageOnBackend(XFile image) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse(_apiUrl));
      
      final bytes = await image.readAsBytes();
      String filename = image.name;
      if (filename.isEmpty) filename = 'upload.jpg';
      
      request.files.add(http.MultipartFile.fromBytes(
        'image', 
        bytes,
        filename: filename,
      ));
      
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        var jsonResponse = jsonDecode(response.body);
        String requestId = jsonResponse['request_id'];
        
        setState(() {
          _recognizedText = "Image submitted. Connecting to WebSocket...";
        });
        
        _connectWebSocket(requestId);
      } else {
        setState(() {
            _recognizedText = "Error from server: ${response.statusCode}\n${response.body}";
            _isRecognizing = false;
        });
      }
    } catch (e) {
      setState(() {
        _recognizedText = "Network error: $e\n\nMake sure the Django server is running and accessible at $_apiUrl";
        _isRecognizing = false;
      });
    }
  }

  void _connectWebSocket(String requestId) {
    // Convert http:// to ws://
    String wsUrl = _apiUrl.replaceFirst('http', 'ws');
    // Remove /api/ocr/ and replace with /ws/ocr/
    wsUrl = wsUrl.replaceAll('/api/ocr/', '/ws/ocr/$requestId/');
    
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    
    _channel!.stream.listen((message) {
      final decoded = jsonDecode(message);
      
      if (decoded['status'] == 'success') {
        setState(() {
          _recognizedText = decoded['data'] != null ? decoded['data'].toString() : "Success but no text returned";
          _isRecognizing = false;
        });
        _channel?.sink.close();
      } else if (decoded['error'] != null) {
        setState(() {
          _recognizedText = "Error: ${decoded['error']}";
          _isRecognizing = false;
        });
        _channel?.sink.close();
      } else {
        // Status update
        setState(() {
          _recognizedText = "Status: ${decoded['status']}\n${decoded['message']}";
        });
      }
    }, onError: (error) {
      setState(() {
        _recognizedText = "WebSocket Error: $error";
        _isRecognizing = false;
      });
    }, onDone: () {
      if (_isRecognizing) {
        setState(() {
          _recognizedText += "\n\nConnection closed.";
          _isRecognizing = false;
        });
      }
    });
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentUrl: _apiUrl,
          onUrlChanged: (newUrl) {
            setState(() {
              _apiUrl = newUrl;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          )
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_image != null)
                kIsWeb
                    ? Image.network(
                        _image!.path,
                        height: 300,
                        fit: BoxFit.contain,
                      )
                    : Image.file(
                        File(_image!.path),
                        height: 300,
                        fit: BoxFit.contain,
                      )
              else
                Container(
                  height: 300,
                  color: Colors.grey[200],
                  child: const Center(
                    child: Text('No image selected.'),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _isRecognizing ? null : () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _isRecognizing ? null : () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Recognized Text:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _isRecognizing
                    ? const Column(
                        children: [
                          Center(child: CircularProgressIndicator()),
                          SizedBox(height: 16),
                          Text("Polling Datalab API...")
                        ]
                      )
                    : SelectableText(
                        _recognizedText,
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final String currentUrl;
  final Function(String) onUrlChanged;

  const SettingsScreen({
    super.key,
    required this.currentUrl,
    required this.onUrlChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final newUrl = _urlController.text.trim();
    await prefs.setString('api_url', newUrl);
    widget.onUrlChanged(newUrl);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved successfully')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Backend API URL',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'http://192.168.1.X:8000/api/ocr/',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'For Android Emulators, use http://10.0.2.2:8000/api/ocr/\nFor physical devices, use your computer\'s local Wi-Fi IP address.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: _saveSettings,
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Save Settings', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
