import 'package:flutter/material.dart';

import 'package:openplants/core/app_scope.dart';
import 'package:openplants/l10n/l10n_x.dart';
import 'package:openplants/pages/ai_diagnosis/ai_diagnosis_service.dart';

/// Lets the user pick the AI provider, paste an API key and optionally override the model.
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  AiProvider _provider = AiProvider.gemini;
  bool _obscureKey = true;
  bool _initialized = false;
  bool _testing = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final settings = AppScope.of(context).settings.settings;
    _provider = AiProviderX.fromId(settings.aiProvider) ?? AiProvider.gemini;
    _keyController.text = settings.aiApiKey ?? '';
    _modelController.text = settings.aiModel ?? '';
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final controller = AppScope.of(context).settings;
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    try {
      await controller.update(
        controller.settings.copyWith(
          aiProvider: key.isEmpty ? null : _provider.id,
          aiApiKey: key.isEmpty ? null : key,
          aiModel: model.isEmpty ? null : model,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.aiSettingsSaved)));
      Navigator.of(context).pop(key.isNotEmpty);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.generalFailureMessage)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final messenger = ScaffoldMessenger.of(context);
    final okText = context.l10n.aiTestOk;
    try {
      await const AiDiagnosisService().testConnection(
        provider: _provider,
        apiKey: _keyController.text,
        model: _modelController.text,
      );
      messenger.showSnackBar(SnackBar(content: Text(okText)));
    } on AiDiagnosisException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), duration: const Duration(seconds: 6)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final providerNote = switch (_provider) {
      AiProvider.gemini => l10n.aiProviderGeminiNote,
      AiProvider.claude => l10n.aiProviderClaudeNote,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiSettingsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l10n.aiProviderLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<AiProvider>(
              segments: AiProvider.values
                  .map((p) => ButtonSegment<AiProvider>(value: p, label: Text(p.displayName)))
                  .toList(),
              selected: {_provider},
              onSelectionChanged: (selection) => setState(() => _provider = selection.first),
            ),
            const SizedBox(height: 10),
            Text(providerNote, style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            TextField(
              controller: _keyController,
              obscureText: _obscureKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.aiApiKeyLabel,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.aiApiKeyHelp, style: theme.textTheme.bodySmall),
            SelectableText(_provider.apiKeyUrl, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(l10n.aiKeyStoredLocally, style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            TextField(
              controller: _modelController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.aiModelLabel,
                hintText: l10n.aiModelHint(_provider.defaultModel),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _testing || _saving ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(l10n.aiTestConnection),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}
