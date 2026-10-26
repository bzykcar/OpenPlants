import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:openplants/core/app_scope.dart';
import 'package:openplants/l10n/l10n_x.dart';
import 'package:openplants/pages/ai_diagnosis/ai_diagnosis_service.dart';
import 'package:openplants/pages/ai_diagnosis/ai_settings_page.dart';
import 'package:openplants/pages/plant_collection/plant_collection_item_entity.dart';
import 'package:openplants/pages/plant_journal/plant_journal_item_entity.dart';

/// Photo-based plant diagnosis using a cloud AI model (Gemini or Claude).
class AiDiagnosisPage extends StatefulWidget {
  /// Preselects this plant when provided.
  final String? plantId;

  /// Optional summary of the rule-based questionnaire, passed to the model as extra context.
  final String? questionnaireSummary;

  const AiDiagnosisPage({super.key, this.plantId, this.questionnaireSummary});

  @override
  State<AiDiagnosisPage> createState() => _AiDiagnosisPageState();
}

class _AiDiagnosisPageState extends State<AiDiagnosisPage> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _descriptionController = TextEditingController();
  final AiDiagnosisService _service = const AiDiagnosisService();

  List<PlantEntity> _plants = const [];
  PlantEntity? _plant;
  String? _pickedPhotoPath;
  bool _loadedPlants = false;
  bool _analyzing = false;
  bool _saving = false;
  bool _saved = false;
  String? _result;
  String? _error;
  AiProvider? _resultProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedPlants) return;
    _loadedPlants = true;
    _loadPlants();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadPlants() async {
    try {
      final plants = await AppScope.of(context).services.plantCollection.loadPlants();
      if (!mounted) return;
      setState(() {
        _plants = plants;
        _plant = plants.where((p) => p.id == widget.plantId).firstOrNull;
      });
    } catch (_) {
      // Plant selection is optional; the page still works without the list.
    }
  }

  String? get _effectivePhotoPath => _pickedPhotoPath ?? _plant?.photoPath;

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await _picker.pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 90);
      if (file == null || !mounted) return;
      setState(() {
        _pickedPhotoPath = file.path;
        _result = null;
        _error = null;
        _saved = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.plantIdFailedToPick)));
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => const AiSettingsPage()));
    if (mounted) setState(() {});
  }

  Future<void> _analyze() async {
    final settings = AppScope.of(context).settings.settings;
    final provider = AiProviderX.fromId(settings.aiProvider);
    final apiKey = settings.aiApiKey;
    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await _openSettings();
      return;
    }

    final photoPath = _effectivePhotoPath;
    final description = _descriptionController.text.trim();
    if (photoPath == null && description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.aiNeedPhotoOrText)));
      return;
    }

    final languageCode = Localizations.localeOf(context).languageCode;
    FocusScope.of(context).unfocus();
    setState(() {
      _analyzing = true;
      _result = null;
      _error = null;
      _saved = false;
    });

    try {
      final image = photoPath == null ? null : await AiDiagnosisService.prepareImage(photoPath);
      final text = await _service.diagnose(
        provider: provider,
        apiKey: apiKey,
        model: settings.aiModel,
        request: AiDiagnosisRequest(
          languageCode: languageCode,
          imageJpeg: image,
          plantName: _plant?.name,
          speciesName: _plant?.speciesName,
          room: _plant?.room,
          userDescription: description,
          questionnaireSummary: widget.questionnaireSummary,
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = text;
        _resultProvider = provider;
      });
    } on AiDiagnosisException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _saveToJournal() async {
    final plant = _plant;
    final result = _result;
    if (plant == null || result == null) return;

    setState(() => _saving = true);
    final l10n = context.l10n;
    final journal = AppScope.of(context).services.plantJournal;
    final messenger = ScaffoldMessenger.of(context);
    final header = l10n.aiJournalHeader(_resultProvider?.displayName ?? 'AI');
    final description = _descriptionController.text.trim();
    final notes = StringBuffer(header)..writeln();
    if (description.isNotEmpty) {
      notes
        ..writeln()
        ..writeln('„$description”');
    }
    notes
      ..writeln()
      ..write(result);

    try {
      await journal.addEntry(
        JournalEntry(
          id: '',
          plantId: plant.id,
          type: JournalEntryType.text,
          timestamp: DateTime.now(),
          notes: notes.toString(),
        ),
        photoFile: _pickedPhotoPath == null ? null : File(_pickedPhotoPath!),
      );
      if (!mounted) return;
      setState(() => _saved = true);
      messenger.showSnackBar(SnackBar(content: Text(l10n.aiSavedToJournal)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.generalFailureMessage)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final settings = AppScope.of(context).settings.settings;
    final provider = AiProviderX.fromId(settings.aiProvider);
    final configured = provider != null && (settings.aiApiKey ?? '').isNotEmpty;
    final photoPath = _effectivePhotoPath;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiDiagnosisTitle),
        actions: [
          IconButton(
            tooltip: l10n.aiSettingsTitle,
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (!configured)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.aiNotConfigured, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.key),
                        label: Text(l10n.aiOpenSettings),
                      ),
                    ],
                  ),
                ),
              )
            else
              Text(l10n.aiPrivacyNote(provider?.displayName ?? 'AI'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            if (_plants.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: _plant?.id ?? '',
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.aiSelectPlant,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem<String>(value: '', child: Text(l10n.aiNoPlant)),
                  ..._plants.map(
                    (p) => DropdownMenuItem<String>(
                      value: p.id,
                      child: Text(
                        p.speciesName == null || p.speciesName!.isEmpty ? p.name : '${p.name} (${p.speciesName})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (id) => setState(() {
                  _plant = _plants.where((p) => p.id == id).firstOrNull;
                  _result = null;
                  _error = null;
                  _saved = false;
                }),
              ),
              const SizedBox(height: 16),
            ],
            Text(l10n.aiPhoto, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (photoPath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.file(File(photoPath), fit: BoxFit.cover),
                ),
              )
            else
              Container(
                height: 120,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(l10n.aiNoPhoto, textAlign: TextAlign.center),
              ),
            if (photoPath != null && _pickedPhotoPath == null) ...[
              const SizedBox(height: 6),
              Text(l10n.aiUsingPlantPhoto, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _analyzing ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera),
                    label: Text(l10n.cameraCapturePhoto),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _analyzing ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: Text(l10n.plantIdGallery),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              minLines: 2,
              maxLines: 5,
              maxLength: 600,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.aiDescriptionLabel,
                hintText: l10n.aiDescriptionHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _analyzing ? null : _analyze,
              icon: _analyzing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(_analyzing ? l10n.aiAnalyzing : l10n.aiAnalyze),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(l10n.aiResultTitle, style: theme.textTheme.titleLarge)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(_cleanMarkdown(_result!), style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      Text(
                        l10n.aiDisclaimer,
                        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                ),
              ),
              if (_plant != null) ...[
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _saving || _saved ? null : _saveToJournal,
                  icon: Icon(_saved ? Icons.check : Icons.book),
                  label: Text(_saved ? l10n.aiSavedToJournal : l10n.aiSaveToJournal),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Removes the most common markdown markers so the plain-text view stays readable.
  static String _cleanMarkdown(String text) {
    return text
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (match) => match.group(1) ?? '')
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[*-]\s+', multiLine: true), '• ');
  }
}
