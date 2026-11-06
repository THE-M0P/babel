// Settings: host + token, persisted on device.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection.dart';
import '../main.dart';

class SettingsScreen extends StatefulWidget {
  final Connection conn;
  const SettingsScreen({super.key, required this.conn});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _token;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController();
    _token = TextEditingController();
    SharedPreferences.getInstance().then((prefs) {
      _host.text = prefs.getString('host') ?? kDefaultHost;
      _token.text = prefs.getString('token') ?? '';
      setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final host = _host.text.trim();
    final token = _token.text.trim();
    if (host.isEmpty || token.isEmpty) {
      // Belt and braces — the button is disabled in this state too.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Host and token are both required')));
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host', host);
    await prefs.setString('token', token);
    widget.conn.connect(host, token);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                        labelText: 'Host (ip:port)',
                        helperText: 'babel host on the tailnet'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _token,
                    decoration: const InputDecoration(
                        labelText: 'Token',
                        helperText: 'contents of ~/.config/babel/token on the laptop'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 24),
                  AnimatedBuilder(
                    // rebuild on either field change
                    animation: Listenable.merge([_host, _token]),
                    builder: (context, _) {
                      final ready = _host.text.trim().isNotEmpty &&
                          _token.text.trim().isNotEmpty;
                      return Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: ready ? _save : null,
                          child: const Text('Save & connect'),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }
}
