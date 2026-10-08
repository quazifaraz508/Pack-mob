import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:fl_chart/fl_chart.dart';

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
  String _rawText = "";
  Map<String, dynamic>? _dashboardData;
  bool _isRecognizing = false;
  String _apiUrl = "https://92xqbtlk-8000.inc1.devtunnels.ms/api/ocr/";

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _reqIdController = TextEditingController();
  WebSocketChannel? _channel;

  @override
  void dispose() {
    _channel?.sink.close();
    _reqIdController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUrl = prefs.getString('api_url') ?? "https://92xqbtlk-8000.inc1.devtunnels.ms/api/ocr/";
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final pickedFile = await _picker.pickImage(source: source);
    if (pickedFile != null) {
      setState(() {
        _image = pickedFile;
        _recognizedText = "Uploading and processing image...\nThis may take a few seconds.";
        _rawText = "";
        _isRecognizing = true;
      });
      await _processImageOnBackend(_image!);
    }
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
          _dashboardData = null;
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
          _rawText = decoded['raw_text']?.toString() ?? '';
          if (decoded['is_structured'] == true) {
            _dashboardData = decoded['data'];
            _recognizedText = "Parsed successfully!";
          } else {
            _dashboardData = null;
            _recognizedText = decoded['data'] != null ? decoded['data'].toString() : "Success but no text returned";
          }
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

  Future<void> _fetchExistingResult() async {
    final reqId = _reqIdController.text.trim();
    if (reqId.isEmpty) return;

    setState(() {
      _isRecognizing = true;
      _recognizedText = "Fetching from server...";
      _rawText = "";
      _dashboardData = null;
    });

    try {
      final fetchUrl = _apiUrl.replaceAll('ocr/', 'fetch/$reqId/');
      final response = await http.get(Uri.parse(fetchUrl));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded['status'] == 'success') {
          setState(() {
            _rawText = decoded['raw_text']?.toString() ?? '';
            if (decoded['is_structured'] == true) {
              _dashboardData = decoded['data'];
              _recognizedText = '';
            } else {
              _recognizedText = decoded['data'].toString();
            }
            _isRecognizing = false;
          });
        } else {
          setState(() {
            _recognizedText = "Error: ${decoded['error']}";
            _isRecognizing = false;
          });
        }
      } else {
        setState(() {
          _recognizedText = "Server Error: ${response.body}";
          _isRecognizing = false;
        });
      }
    } catch (e) {
      setState(() {
        _recognizedText = "Network Error: $e";
        _isRecognizing = false;
      });
    }
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
        title: const Text('Scanner'),
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
              const Divider(),
              const SizedBox(height: 10),
              const Text('Or use an existing Datalab Request ID:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _reqIdController,
                      decoration: const InputDecoration(
                        hintText: 'Enter request_id',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isRecognizing ? null : _fetchExistingResult,
                    child: const Text('Fetch'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 20),
              if (_rawText.isNotEmpty) ...[
                const Text('Raw OCR Text:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(_rawText),
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 20),
              ],
              const Text(
                'Recognized Result:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              if (_dashboardData != null && _dashboardData!['visualizations'] != null) ...[
                const SizedBox(height: 20),
                ...(_dashboardData!['visualizations'] as List).map((viz) {
                  final String type = viz['chart_type']?.toString() ?? '';
                  final String title = viz['title']?.toString() ?? 'Chart';
                  final List<dynamic> data = viz['data'] ?? [];

                  if (data.isEmpty) return const SizedBox.shrink();

                  Widget chartWidget = const SizedBox.shrink();

                  if (type == 'pie_chart') {
                    chartWidget = SizedBox(
                      height: 250,
                      child: PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 40,
                          sections: data.asMap().entries.map((entry) {
                            int idx = entry.key;
                            var item = entry.value;
                            double val = 0.0;
                            if (item is Map && item['value'] != null) {
                              if (item['value'] is num) {
                                val = (item['value'] as num).toDouble();
                              } else {
                                val = double.tryParse(item['value'].toString()) ?? 0.0;
                              }
                            }
                            String label = item is Map ? (item['label']?.toString() ?? 'Unknown') : 'Unknown';
                            String unit = item is Map ? (item['unit']?.toString() ?? '') : '';
                            return PieChartSectionData(
                              value: val > 0 ? val : 1,
                              title: '$label\n$val$unit',
                              radius: 80,
                              titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                              color: Colors.primaries[idx % Colors.primaries.length],
                            );
                          }).toList(),
                        )
                      )
                    );
                  } else if (type == 'bar_chart') {
                    chartWidget = SizedBox(
                      height: 250,
                      child: BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                getTitlesWidget: (double value, TitleMeta meta) {
                                  if (value.toInt() >= 0 && value.toInt() < data.length) {
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 8.0),
                                      child: Text(data[value.toInt()]['label']?.toString() ?? '', style: const TextStyle(fontSize: 10)),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                            ),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(show: false),
                          barGroups: data.asMap().entries.map((entry) {
                            int idx = entry.key;
                            var item = entry.value;
                            double val = 0.0;
                            if (item is Map && item['value'] != null) {
                              if (item['value'] is num) {
                                val = (item['value'] as num).toDouble();
                              } else {
                                val = double.tryParse(item['value'].toString()) ?? 0.0;
                              }
                            }
                            return BarChartGroupData(
                              x: idx,
                              barRods: [
                                BarChartRodData(
                                  toY: val,
                                  color: Colors.primaries[idx % Colors.primaries.length],
                                  width: 16,
                                  borderRadius: BorderRadius.circular(4),
                                )
                              ],
                            );
                          }).toList(),
                        )
                      )
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      chartWidget,
                      const SizedBox(height: 10),
                      ...data.map((item) {
                        String label = item is Map ? (item['label']?.toString() ?? 'Unknown') : item.toString();
                        String valStr = item is Map ? (item['value']?.toString() ?? '0') : '0';
                        String unit = item is Map ? (item['unit']?.toString() ?? '') : '';
                        return Card(
                          child: ListTile(
                            title: Text(label),
                            trailing: Text('$valStr$unit', style: const TextStyle(fontWeight: FontWeight.bold)),
                            leading: CircleAvatar(
                              backgroundColor: Colors.primaries[data.indexOf(item) % Colors.primaries.length],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 30),
                    ],
                  );
                }),
              ] else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _isRecognizing
                      ? Column(
                          children: [
                            const Center(child: CircularProgressIndicator()),
                            const SizedBox(height: 16),
                            Text("Processing...")
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
              'For local development, use https://92xqbtlk-8000.inc1.devtunnels.ms/api/ocr/\nFor other servers, enter the full URL.',
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
