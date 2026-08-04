import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/workspace_context.dart';
import '../providers/workspace_provider.dart';

class WorkspaceSetupScreen extends ConsumerStatefulWidget {
  const WorkspaceSetupScreen({super.key});

  @override
  ConsumerState<WorkspaceSetupScreen> createState() =>
      _WorkspaceSetupScreenState();
}

class _WorkspaceSetupScreenState extends ConsumerState<WorkspaceSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _workspaceController = TextEditingController();
  final _locationController = TextEditingController();
  final _currencyController = TextEditingController();

  @override
  void dispose() {
    _workspaceController.dispose();
    _locationController.dispose();
    _currencyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workspaceProvider);
    final workspace = state.activeWorkspace;
    final createsWorkspace = workspace == null;
    final canCreateLocation = workspace?.role == WorkspaceRole.owner;
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    createsWorkspace
                        ? Icons.domain_add_outlined
                        : Icons.add_business_outlined,
                    size: 48,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    createsWorkspace
                        ? 'Create your workspace'
                        : 'Add your first location',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    createsWorkspace
                        ? 'Use your real restaurant and location names. Existing data is never assigned automatically.'
                        : canCreateLocation
                        ? 'Dashboard and Reports require an explicitly owned location.'
                        : 'A workspace owner must add a location before Dashboard and Reports are available.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  if (!createsWorkspace && !canCreateLocation) ...[
                    OutlinedButton.icon(
                      key: const Key('workspace-retry-button'),
                      onPressed: state.isLoading
                          ? null
                          : ref.read(workspaceProvider.notifier).load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Refresh access'),
                    ),
                  ] else
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (createsWorkspace) ...[
                            TextFormField(
                              key: const Key('workspace-name-field'),
                              controller: _workspaceController,
                              enabled: !state.isSubmitting,
                              maxLength: 120,
                              decoration: const InputDecoration(
                                labelText: 'Workspace name',
                                hintText: 'Restaurant or restaurant group',
                                prefixIcon: Icon(Icons.domain_outlined),
                              ),
                              validator: _requiredName,
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            key: const Key('workspace-location-field'),
                            controller: _locationController,
                            enabled: !state.isSubmitting,
                            maxLength: 120,
                            decoration: const InputDecoration(
                              labelText: 'Location name',
                              hintText: 'Branch or venue name',
                              prefixIcon: Icon(Icons.location_on_outlined),
                            ),
                            validator: _requiredName,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const Key('workspace-currency-field'),
                            controller: _currencyController,
                            enabled: !state.isSubmitting,
                            maxLength: 3,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Currency code',
                              hintText: 'Three-letter ISO code',
                              prefixIcon: Icon(Icons.payments_outlined),
                            ),
                            validator: _currency,
                          ),
                          if (state.submissionError != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              state.submissionError!,
                              key: const Key('workspace-submission-error'),
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            key: const Key('workspace-submit-button'),
                            onPressed: state.isSubmitting ? null : _submit,
                            icon: state.isSubmitting
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check_rounded),
                            label: Text(
                              state.isSubmitting
                                  ? 'Saving…'
                                  : createsWorkspace
                                  ? 'Create workspace'
                                  : 'Add location',
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    ref.read(workspaceProvider.notifier).clearSubmissionError();
    if (!_formKey.currentState!.validate()) return;
    final notifier = ref.read(workspaceProvider.notifier);
    final state = ref.read(workspaceProvider);
    final currency = _currencyController.text.trim().toUpperCase();
    final success = state.activeWorkspace == null
        ? await notifier.createWorkspace(
            name: _workspaceController.text.trim(),
            locationName: _locationController.text.trim(),
            currencyCode: currency,
          )
        : await notifier.createLocation(
            name: _locationController.text.trim(),
            currencyCode: currency,
          );
    if (!success || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Workspace context is ready.')),
    );
  }

  static String? _requiredName(String? value) {
    if (value == null || value.trim().isEmpty) return 'This field is required.';
    return null;
  }

  static String? _currency(String? value) {
    final normalized = value?.trim() ?? '';
    if (!RegExp(r'^[A-Za-z]{3}$').hasMatch(normalized)) {
      return 'Enter a three-letter currency code.';
    }
    return null;
  }
}
