import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';

void main() {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Ozon TSD',
    theme: ThemeData(primarySwatch: Colors.blue),
    home: TsdMainScreen(),
  ));
}

class OzonOrder {
  final String orderId;
  final String postingNumber;
  final List<OzonItem> items;
  bool isReadyToShip;

  OzonOrder({required this.orderId, required this.postingNumber, required this.items, this.isReadyToShip = false});
}

class OzonItem {
  final String sku;
  final String name;
  final int quantity;
  final String imageUrl;
  final String barcode;

  OzonItem({required this.sku, required this.name, required this.quantity, required this.imageUrl, required this.barcode});
}

class SettingsService {
  static const String _keyClientId = 'ozon_client_id';
  static const String _keyApiKey = 'ozon_api_key';

  static Future<void> saveCredentials(String clientId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyClientId, clientId.trim());
    await prefs.setString(_keyApiKey, apiKey.trim());
  }

  static Future<String> getClientId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyClientId) ?? '';
  }

  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey) ?? '';
  }
}

class OzonService {
  final String baseUrl = 'https://api-seller.ozon.ru';

  Future<List<OzonOrder>> fetchOrdersToShip() async {
    final clientId = await SettingsService.getClientId();
    final apiKey = await SettingsService.getApiKey();

    if (clientId.isEmpty || apiKey.isEmpty) {
      throw Exception('Не заполнены Client ID или API Key в настройках!');
    }

    final url = Uri.parse('$baseUrl/v3/posting/fbs/list');
    final response = await http.post(
      url,
      headers: {
        'Client-Id': clientId,
        'Api-Key': apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        "dir": "ASC",
        "filter": {"status": "awaiting_packaging"},
        "limit": 50,
        "offset": 0,
        "with": {"analytics_data": false, "barcodes": true}
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List postings = data['result']['postings'] ?? [];

      return postings.map((p) {
        var products = (p['products'] as List).map((item) {
          return OzonItem(
            sku: item['sku'].toString(),
            name: item['name'] ?? 'Товар без названия',
            quantity: item['quantity'] ?? 1,
            imageUrl: item['images'] != null && (item['images'] as List).isNotEmpty ? item['images'][0] : '',
            barcode: item['barcodes'] != null && (item['barcodes'] as List).isNotEmpty ? item['barcodes'][0] : item['sku'].toString(),
          );
        }).toList();

        return OzonOrder(
          orderId: p['order_id'].toString(),
          postingNumber: p['posting_number'].toString(),
          items: products,
          isReadyToShip: false,
        );
      }).toList();
    } else {
      throw Exception('Ошибка API Ozon: ${response.body}');
    }
  }
}

class PrinterService {
  BlueThermalPrinter bluetooth = BlueThermalPrinter.instance;

  Future<void> connectPrinter(BuildContext context) async {
    List<BluetoothDevice> devices = [];
    try {
      devices = await bluetooth.getBondedDevices();
    } catch (_) {}

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Выберите Bluetooth принтер'),
        content: Container(
          width: 300,
          height: 300,
          child: ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              return ListTile(
                title: Text(devices[index].name ?? 'Устройство'),
                subtitle: Text(devices[index].address ?? ''),
                onTap: () {
                  bluetooth.connect(devices[index]);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Подключено')));
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> printLabel(OzonOrder order) async {
    bool? isConnected = await bluetooth.isConnected;
    if (isConnected == true) {
      bluetooth.printNewLine();
      bluetooth.printCustom("OZON FBS ORDER", 2, 1);
      bluetooth.printCustom("Posting: ${order.postingNumber}", 1, 1);
      bluetooth.printBarCode(order.postingNumber);
      bluetooth.printNewLine();
      for (var item in order.items) {
        bluetooth.printLeftRight(item.name, "x${item.quantity}", 1);
        bluetooth.printBarCode(item.barcode);
      }
      bluetooth.printNewLine();
      bluetooth.paperCut();
    }
  }
}

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _clientIdController = TextEditingController();
  final _apiKeyController = TextEditingController();
  bool _obscureApiKey = true;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    _clientIdController.text = await SettingsService.getClientId();
    _apiKeyController.text = await SettingsService.getApiKey();
    setState(() {});
  }

  Future<void> _saveData() async {
    await SettingsService.saveCredentials(_clientIdController.text, _apiKeyController.text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Сохранено!'), backgroundColor: Colors.green));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Настройки Ozon API')),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: ListView(
          children: [
            TextField(controller: _clientIdController, decoration: InputDecoration(labelText: 'Client ID', border: OutlineInputBorder()), keyboardType: TextInputType.number),
            SizedBox(height: 16),
            TextField(controller: _apiKeyController, obscureText: _obscureApiKey, decoration: InputDecoration(labelText: 'API Key', border: OutlineInputBorder(), suffixIcon: IconButton(icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey)))),
            SizedBox(height: 24),
            ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white), icon: Icon(Icons.save), label: Text('Сохранить'), onPressed: _saveData),
          ],
        ),
      ),
    );
  }
}

class TsdMainScreen extends StatefulWidget {
  @override
  _TsdMainScreenState createState() => _TsdMainScreenState();
}

class _TsdMainScreenState extends State<TsdMainScreen> {
  final OzonService _ozonService = OzonService();
  final PrinterService _printerService = PrinterService();
  List<OzonOrder> _orders = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _isLoading = true);
    try {
      _orders = await _ozonService.fetchOrdersToShip();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('ТСД Озон'),
        actions: [
          IconButton(icon: Icon(Icons.refresh), onPressed: _loadOrders),
          IconButton(icon: Icon(Icons.bluetooth), onPressed: () => _printerService.connectPrinter(context)),
          IconButton(icon: Icon(Icons.settings), onPressed: () async {
            final res = await Navigator.push(context, MaterialPageRoute(builder: (context) => SettingsScreen()));
            if (res == true) _loadOrders();
          }),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _orders.length,
              itemBuilder: (context, index) {
                final order = _orders[index];
                return Card(
                  margin: EdgeInsets.all(8),
                  color: order.isReadyToShip ? Colors.green[50] : Colors.white,
                  child: ExpansionTile(
                    leading: Icon(order.isReadyToShip ? Icons.check_circle : Icons.pending, color: order.isReadyToShip ? Colors.green : Colors.orange),
                    title: Text('Заказ: ${order.postingNumber}', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(order.isReadyToShip ? 'ГОТОВ К ОТГРУЗКЕ' : 'Сборка'),
                    children: [
                      ...order.items.map((item) => ListTile(
                        leading: item.imageUrl.isNotEmpty ? Image.network(item.imageUrl, width: 50, height: 50, fit: BoxFit.cover) : Icon(Icons.image, size: 50),
                        title: Text(item.name, maxLines: 2),
                        subtitle: Text('Кол-во: ${item.quantity} | ШК: ${item.barcode}'),
                      )),
                      Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                              icon: Icon(Icons.print),
                              label: Text('Печать'),
                              onPressed: () => _printerService.printLabel(order),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: order.isReadyToShip ? Colors.green : Colors.orange, foregroundColor: Colors.white),
                              icon: Icon(Icons.qr_code_scanner),
                              label: Text(order.isReadyToShip ? 'Проверено' : 'Сканировать'),
                              onPressed: order.isReadyToShip ? null : () async {
                                setState(() => order.isReadyToShip = true);
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Заказ готов к отгрузке!'), backgroundColor: Colors.green));
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
