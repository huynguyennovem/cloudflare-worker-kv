import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:flutter/material.dart';

// Pass your deployed Worker URL at build time:
//   flutter run --dart-define=CF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev \
//               --dart-define=CF_CLIENT_KEY=optional-key
const endpoint = String.fromEnvironment('CF_CONFIG_ENDPOINT');
const clientKey = String.fromEnvironment('CF_CLIENT_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (endpoint.isEmpty) {
    runApp(const MissingEndpointApp());
    return;
  }

  final remoteConfig = await CloudflareRemoteConfig.initialize(
    endpoint: Uri.parse(endpoint),
    clientKey: clientKey.isEmpty ? null : clientKey,
  );
  await remoteConfig.setConfigSettings(
    RemoteConfigSettings(
      fetchTimeout: const Duration(seconds: 10),
      // Use a long interval (e.g. 1 hour) in production.
      minimumFetchInterval: Duration.zero,
    ),
  );
  await remoteConfig.setDefaults(const {
    'welcome_message': 'Hello from defaults',
    'max_items': 5,
    'discount_ratio': 0.0,
    'new_checkout_enabled': false,
  });

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cloudflare_worker_kv example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFF38020)),
      home: const ConfigPage(),
    );
  }
}

class MissingEndpointApp extends StatelessWidget {
  const MissingEndpointApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: SelectableText(
              'Run the example with your Worker URL:\n\n'
              'flutter run --dart-define=CF_CONFIG_ENDPOINT='
              'https://<worker>.<subdomain>.workers.dev',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final _remoteConfig = CloudflareRemoteConfig.instance;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    String message;
    try {
      final activated = await _remoteConfig.fetchAndActivate();
      message = activated ? 'New config activated' : 'Config is up to date';
    } on RemoteConfigException catch (e) {
      message = 'Fetch failed: ${e.code}';
    }
    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final values = _remoteConfig.getAll().entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final checkoutEnabled = _remoteConfig.getBool('new_checkout_enabled');

    return Scaffold(
      appBar: AppBar(title: const Text('Cloudflare Remote Config')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _refresh,
        icon: _loading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh),
        label: const Text('Fetch & activate'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            _remoteConfig.getString('welcome_message'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Max items: ${_remoteConfig.getInt('max_items')} · '
            'Discount: ${(_remoteConfig.getDouble('discount_ratio') * 100).toStringAsFixed(0)}%',
          ),
          const SizedBox(height: 8),
          Chip(
            avatar: Icon(checkoutEnabled ? Icons.check_circle : Icons.cancel),
            label: Text(
              'New checkout ${checkoutEnabled ? 'enabled' : 'disabled'}',
            ),
          ),
          const Divider(height: 32),
          Text('Status: ${_remoteConfig.lastFetchStatus.name}'),
          Text(
            'Last fetch: ${_remoteConfig.lastFetchTime.millisecondsSinceEpoch == 0 ? 'never' : _remoteConfig.lastFetchTime.toLocal()}',
          ),
          Text('Endpoint: $endpoint'),
          const Divider(height: 32),
          for (final entry in values)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(entry.key),
              subtitle: Text(entry.value.asString()),
              trailing: Text(entry.value.source.name),
            ),
        ],
      ),
    );
  }
}
