import 'package:flutter/material.dart';

import 'package:openplants/core/app_scope.dart';
import 'package:openplants/l10n/l10n_x.dart';
import 'package:openplants/pages/ai_diagnosis/ai_diagnosis_service.dart';
import 'package:openplants/pages/ai_diagnosis/ai_settings_page.dart';
import 'package:openplants/pages/care_schedule/care_task_type.dart';
import 'package:openplants/pages/plant_collection/plant_collection_item_entity.dart';
import 'package:openplants/pages/plant_journal/plant_journal_item_entity.dart';

/// Button that asks the AI for a care schedule and saves it as the plant's care rules.
class AiCarePlanButton extends StatefulWidget {
  final PlantEntity plant;
  final String? roomName;

  /// Called after the rules were saved, so the parent can refresh.
  final VoidCallback onApplied;

  const AiCarePlanButton({
    super.key,
    required this.plant,
    required this.onApplied,
    this.roomName,
  });

  @override
  State<AiCarePlanButton> createState() => _AiCarePlanButtonState();
}

class _AiCarePlanButtonState extends State<AiCarePlanButton> {
  bool _loading = false;

  Future<void> _run() async {
    var settings = AppScope.of(context).settings.settings;
    if (AiProviderX.fromId(settings.aiProvider) == null || (settings.aiApiKey ?? '').isEmpty) {
      await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => const AiSettingsPage()));
      if (!mounted) return;
      settings = AppScope.of(context).settings.settings;
    }
    final provider = AiProviderX.fromId(settings.aiProvider);
    final apiKey = settings.aiApiKey;
    if (provider == null || apiKey == null || apiKey.isEmpty) return;

    final plant = widget.plant;
    final languageCode = Localizations.localeOf(context).languageCode;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loading = true);

    AiCarePlan plan;
    try {
      final hasSpecies = (plant.speciesName ?? '').trim().isNotEmpty;
      final photo = plant.photoPath;
      final image = (!hasSpecies && photo != null) ? await AiDiagnosisService.prepareImage(photo) : null;
      plan = await const AiDiagnosisService().suggestCarePlan(
        provider: provider,
        apiKey: apiKey,
        model: settings.aiModel,
        languageCode: languageCode,
        speciesName: plant.speciesName,
        plantName: plant.name,
        room: widget.roomName ?? plant.room,
        lightLevel: plant.lightLevel?.name,
        imageJpeg: image,
      );
    } on AiDiagnosisException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), duration: const Duration(seconds: 6)));
      if (mounted) setState(() => _loading = false);
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      if (mounted) setState(() => _loading = false);
      return;
    }

    if (!mounted) return;
    setState(() => _loading = false);
    final apply = await _showPlan(plan);
    if (apply != true || !mounted) return;
    await _apply(plan);
  }

  Future<bool?> _showPlan(AiCarePlan plan) {
    final l10n = context.l10n;
    String every(int days) => days <= 0 ? l10n.aiCarePlanSkip : l10n.aiCarePlanEvery(days);

    return showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        Widget row(IconData icon, String label, String value) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label)),
                  Text(value, style: theme.textTheme.titleSmall),
                ],
              ),
            );

        return AlertDialog(
          title: Text(l10n.aiCarePlanTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (plan.species.isNotEmpty) ...[
                  Text(plan.species, style: theme.textTheme.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
                  const SizedBox(height: 8),
                ],
                row(Icons.water_drop, l10n.taskTypeWater, every(plan.wateringDays)),
                row(Icons.grass, l10n.taskTypeFertilize, every(plan.fertilizingDays)),
                row(Icons.water, l10n.taskTypeMist, every(plan.mistingDays)),
                row(Icons.yard, l10n.taskTypeRepot, every(plan.repottingDays)),
                if (plan.summary.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(plan.summary, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 12),
                Text(l10n.aiCarePlanHint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.aiCarePlanApply)),
          ],
        );
      },
    );
  }

  Future<void> _apply(AiCarePlan plan) async {
    final services = AppScope.of(context).services;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final plantId = widget.plant.id;

    final entries = <BuiltInTaskType, int>{
      BuiltInTaskType.watering: plan.wateringDays,
      BuiltInTaskType.fertilizing: plan.fertilizingDays,
      BuiltInTaskType.misting: plan.mistingDays,
      BuiltInTaskType.repotting: plan.repottingDays,
    };

    try {
      for (final entry in entries.entries) {
        final enabled = entry.value > 0;
        final exists = await services.customCareRules.hasCustomRuleForTaskType(plantId, entry.key.name);
        if (!enabled && !exists) continue;
        await services.customCareRules.createOrUpdateOverride(
          plantId: plantId,
          taskType: entry.key.name,
          intervalDays: enabled ? entry.value : 30,
          isEnabled: enabled,
          reminderEnabled: enabled,
          reminderTime: enabled ? '09:00' : null,
          clearReminderTime: !enabled,
        );
      }

      if (plan.summary.isNotEmpty) {
        try {
          await services.plantJournal.addEntry(
            JournalEntry(
              id: '',
              plantId: plantId,
              type: JournalEntryType.text,
              timestamp: DateTime.now(),
              notes: '${l10n.aiCarePlanTitle}${plan.species.isEmpty ? '' : ' — ${plan.species}'}\n\n${plan.summary}',
            ),
          );
        } catch (_) {
          // The schedule itself is saved; the journal note is a nice-to-have.
        }
      }

      widget.onApplied();
      messenger.showSnackBar(SnackBar(content: Text(l10n.aiCarePlanApplied)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${l10n.generalFailureMessage} $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _loading ? null : _run,
        icon: _loading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_awesome),
        label: Text(_loading ? l10n.aiCarePlanLoading : l10n.aiCarePlanButton),
      ),
    );
  }
}
