import 'dart:async';

import '../models/cron_job.dart';
import 'connection_manager.dart';

enum CronProfileScope { active, all }

class CronJobListing {
  final List<CronJob> jobs;
  final CronProfileScope requestedScope;
  final bool usedLegacyActiveFallback;

  const CronJobListing({
    required this.jobs,
    required this.requestedScope,
    this.usedLegacyActiveFallback = false,
  });
}

/// "Run now" was accepted and the job is still running.
///
/// The trigger route answers only when the whole job has finished
/// (hermes_cli/web_routers/cron.py `_trigger_cron_job_sync` fires the job,
/// then re-reads it), which for an agent job is minutes. Desktop holds that
/// one request open for up to a day (apps/desktop/src/api/cron.ts
/// `CRON_TRIGGER_REQUEST_TIMEOUT_MS`); a phone does not, so no answer
/// within [CronRepository.triggerWait] means the run is going, not that it
/// failed. The job list shows how it ends.
class CronRunInProgress implements Exception {
  final String jobId;

  const CronRunInProgress(this.jobId);

  @override
  String toString() => 'CronRunInProgress($jobId)';
}

/// Reply of the cancel route (hermes_cli/web_routers/cron.py
/// `_cancel_cron_job_sync`).
class CronCancelResult {
  /// False when the job had no run in flight: nothing was stopped.
  final bool cancelled;

  /// The attempt the cancel reached; '' when the server did not name it.
  final String executionId;

  const CronCancelResult({required this.cancelled, this.executionId = ''});
}

/// Contrato móvil de Cron, construido sobre los mismos endpoints que Desktop.
class CronRepository {
  final DashboardClient client;
  final String profile;
  final bool botRoutines;

  /// How long "run now" waits for the job to finish before reporting it as
  /// still running ([CronRunInProgress]).
  final Duration triggerWait;

  const CronRepository(
    this.client, {
    this.profile = '',
    this.botRoutines = false,
    this.triggerWait = const Duration(seconds: 10),
  });

  String _query({bool hasQuery = false}) {
    if (profile.isEmpty) return '';
    return '${hasQuery ? '&' : '?'}profile=${Uri.encodeQueryComponent(profile)}';
  }

  Future<List<CronJob>> listJobs() async =>
      (await listJobsForScope(CronProfileScope.active)).jobs;

  /// The profile a "this profile" read names. An unscoped
  /// `GET /api/cron/jobs` means `all` on the server (`profile: str = "all"`
  /// in `hermes_cli/web_routers/cron.py`), so the default profile is asked
  /// for by name, as Desktop does (`api/cron.ts` `getCronJobs(profile)` with
  /// the scope's profile, `app/cron/index.tsx` `cronProfileForScope`).
  String get _ownProfile => profile.isEmpty ? 'default' : profile;

  /// Amplía la consulta a todos los perfiles sin cambiar [profile], que sigue
  /// siendo el perfil operativo usado por CRUD. Dashboards anteriores a
  /// `profile=all` degradan a la lectura del perfil activo.
  Future<CronJobListing> listJobsForScope(CronProfileScope scope) async {
    if (scope == CronProfileScope.active) {
      return CronJobListing(
        jobs: await _listJobsWithProfile(_ownProfile),
        requestedScope: scope,
      );
    }
    try {
      return CronJobListing(
        jobs: await _listJobsWithProfile('all'),
        requestedScope: scope,
      );
    } on DashboardHttpException catch (error) {
      if (!_isUnsupportedAllProfiles(error.statusCode)) rethrow;
      return CronJobListing(
        jobs: await _listJobsWithProfile(_ownProfile),
        requestedScope: scope,
        usedLegacyActiveFallback: true,
      );
    }
  }

  Future<List<CronJob>> _listJobsWithProfile(String selectedProfile) async {
    final suffix = selectedProfile.isEmpty
        ? ''
        : '?profile=${Uri.encodeQueryComponent(selectedProfile)}';
    final data = await client.apiGetList('cron/jobs$suffix');
    // Record where each job was read from. The server's per-job `profile`
    // wins; without it a named read came from that profile and an unscoped
    // read from the server's default store. An aggregated read (`all`)
    // without it records nothing, so actions fall back to the bot owner or
    // refuse.
    final listed = switch (selectedProfile) {
      'all' => null,
      '' => 'default',
      final named => named,
    };
    return data
        .whereType<Map>()
        .map(
          (value) => CronJob.fromJson(
            value.cast<String, dynamic>(),
          ).withSourceProfile(listed),
        )
        .where((job) => job.id.isNotEmpty)
        .toList(growable: false);
  }

  /// `?profile=` (or `&profile=`) for an action on [job]: the profile that
  /// owns it, never this repository's screen profile. The default profile
  /// sends no query, the same as every other default-profile call.
  static String _ownerQuery(CronJob job, {bool hasQuery = false}) {
    final owner = ownerProfileOf(job);
    if (owner == 'default') return '';
    return '${hasQuery ? '&' : '?'}profile=${Uri.encodeQueryComponent(owner)}';
  }

  /// Profile that owns [job]; throws [CronJobOwnerUnknownException] when it
  /// cannot be told, so nothing is sent to a guessed profile.
  static String ownerProfileOf(CronJob job) {
    final owner = job.targetProfile;
    if (owner == null) throw CronJobOwnerUnknownException(job.id);
    return owner;
  }

  /// Runs an action on [job] in its owner profile. A 404 there means the
  /// job is not in that profile: typed, never a success.
  static Future<CronJob> _onOwner(
    CronJob job,
    Future<Map<String, dynamic>> Function(String query) send, {
    bool hasQuery = false,
  }) async {
    final query = _ownerQuery(job, hasQuery: hasQuery);
    final owner = ownerProfileOf(job);
    try {
      return CronJob.fromJson(await send(query)).withSourceProfile(owner);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) throw CronJobNotFoundException(owner);
      rethrow;
    }
  }

  static bool _isUnsupportedAllProfiles(int statusCode) =>
      statusCode == 400 ||
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 422 ||
      statusCode == 501;

  /// [profile] is the job's owner when known (see [CronJob.targetProfile]);
  /// otherwise this repository's profile is used.
  Future<CronJob?> getJob(String id, {String? profile}) async {
    final owner = profile?.trim() ?? '';
    final query = owner.isEmpty
        ? _query()
        : owner == 'default'
        ? ''
        : '?profile=${Uri.encodeQueryComponent(owner)}';
    try {
      final job = CronJob.fromJson(
        await client.apiGet('cron/jobs/${Uri.encodeComponent(id)}$query'),
      ).withSourceProfile(
        owner.isNotEmpty
            ? owner
            : (this.profile.isEmpty ? 'default' : this.profile),
      );
      return job.id.isEmpty ? null : job;
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Job [id] as the job list of this repository's profile shows it, with
  /// the execution ledger that a single-job read lacks (Desktop reads the
  /// job it shows from the list). Falls back to [getJob] when the list
  /// does not hold it or the server cannot list; null when neither has it.
  Future<CronJob?> listedJob(String id) async {
    try {
      final jobs = await _listJobsWithProfile(
        profile.isEmpty ? 'default' : profile,
      );
      for (final job in jobs) {
        if (job.id == id) return job;
      }
    } on DashboardHttpException catch (error) {
      if (error.statusCode != 404 && error.statusCode != 405) rethrow;
    }
    return getJob(id);
  }

  Future<CronRuns> listRuns(String id, {int limit = 20}) async {
    try {
      final data = await client.apiGet(
        'cron/jobs/${Uri.encodeComponent(id)}/runs?limit=$limit${_query(hasQuery: true)}',
      );
      final raw = data['runs'] ?? data['data'];
      final sessions = (raw as List? ?? const [])
          .map(Session.tryParse)
          .whereType<Session>()
          .toList(growable: false);
      return CronRuns(sessions);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        return const CronRuns([], available: false);
      }
      rethrow;
    }
  }

  /// The delivery targets of [profile]'s gateways: the server reads them
  /// inside the profile it is told (hermes_cli/web_routers/cron.py
  /// `get_cron_delivery_targets`), and Desktop names it
  /// (apps/desktop/src/api/cron.ts `getCronDeliveryTargets`). Without it the
  /// form offered the platforms of the profile the server was started as.
  Future<List<CronDeliveryTarget>> deliveryTargets() async {
    try {
      final data = await client.apiGet('cron/delivery-targets${_query()}');
      final targets = (data['targets'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                CronDeliveryTarget.fromJson(value.cast<String, dynamic>()),
          )
          .where((value) => value.id.isNotEmpty)
          .toList(growable: false);
      return targets.isEmpty ? const [CronDeliveryTarget.local] : targets;
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) {
        return const [CronDeliveryTarget.local];
      }
      rethrow;
    }
  }

  /// The catalog is per profile (built-ins plus that profile's plugin
  /// blueprints), so it is read for the profile [instantiateBlueprint]
  /// creates into, as Desktop does (`getAutomationBlueprints(profile)`).
  Future<List<AutomationBlueprint>> blueprints() async {
    try {
      final targetProfile = profile.isEmpty ? 'default' : profile;
      final data = await client.apiGet(
        'cron/blueprints?profile=${Uri.encodeQueryComponent(targetProfile)}',
      );
      return (data['blueprints'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                AutomationBlueprint.fromJson(value.cast<String, dynamic>()),
          )
          .where((value) => value.key.isNotEmpty)
          .toList(growable: false);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return const [];
      rethrow;
    }
  }

  Future<List<ModelProvider>> modelOptions() async {
    try {
      return await client.getModelOptions(
        profile: profile.isEmpty ? null : profile,
        explicitOnly: true,
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 405) return const [];
      rethrow;
    }
  }

  Future<CronEditorResources> editorResources() async {
    Future<List<CronDeliveryTarget>> safeTargets() async {
      try {
        return await deliveryTargets();
      } catch (_) {
        return const [CronDeliveryTarget.local];
      }
    }

    Future<List<ModelProvider>> safeModels() async {
      try {
        return await modelOptions();
      } catch (_) {
        return const [];
      }
    }

    Future<List<AutomationBlueprint>> safeBlueprints() async {
      try {
        return await blueprints();
      } catch (_) {
        return const [];
      }
    }

    final results = await Future.wait<Object>([
      safeTargets(),
      safeModels(),
      safeBlueprints(),
    ]);
    return CronEditorResources(
      deliveryTargets: results[0] as List<CronDeliveryTarget>,
      modelProviders: results[1] as List<ModelProvider>,
      blueprints: results[2] as List<AutomationBlueprint>,
    );
  }

  /// [catchUp] is sent only when it is not the server default, as Desktop
  /// does (apps/desktop/src/app/cron/index.tsx `createCronJob` call).
  Future<CronJob> create({
    required String name,
    required String prompt,
    required String schedule,
    required String deliver,
    required String model,
    required String provider,
    CronCatchUp catchUp = CronCatchUp.serverDefault,
  }) async {
    final data = await client.apiPost(
      'cron/jobs${_query()}',
      body: {
        'prompt': prompt,
        'schedule': schedule,
        if (botRoutines) 'name': botRoutineName(profile, name, prompt)
        else if (name.isNotEmpty) 'name': name,
        'deliver': deliver.isEmpty ? 'local' : deliver,
        if (model.isNotEmpty) 'model': model,
        if (model.isNotEmpty && provider.isNotEmpty) 'provider': provider,
        if (catchUp.wire != null) 'catch_up': catchUp.wire,
      },
    );
    // Created in this repository's profile.
    return CronJob.fromJson(
      data,
    ).withSourceProfile(profile.isEmpty ? 'default' : profile);
  }

  /// [catchUp] is sent only when given (the user changed it), so an edit
  /// never rewrites a policy it did not touch: Desktop
  /// `buildCronJobUpdates` (apps/desktop/src/app/cron/cron-job-model.ts).
  Future<CronJob> update(
    CronJob job, {
    required String name,
    required String prompt,
    required String schedule,
    required String deliver,
    required String model,
    required String provider,
    CronCatchUp? catchUp,
  }) async {
    final owner = ownerProfileOf(job);
    final updates = <String, dynamic>{
      'name': botRoutines ? botRoutineName(owner, name, prompt) : name,
      'schedule': schedule,
      'deliver': deliver,
      if (!job.isScriptOnly || prompt.isNotEmpty) 'prompt': prompt,
      if (!job.isScriptOnly) 'model': model.isEmpty ? null : model,
      if (!job.isScriptOnly) 'provider': provider.isEmpty ? null : provider,
      if (catchUp != null) 'catch_up': catchUp.wire,
    };
    return _onOwner(
      job,
      (query) => client.apiPut(
        'cron/jobs/${Uri.encodeComponent(job.id)}$query',
        body: {'updates': updates},
      ),
    );
  }

  Future<CronJob> pauseOrResume(CronJob job) {
    final action = job.isPaused ? 'resume' : 'pause';
    return _onOwner(
      job,
      (query) => client.apiPost(
        'cron/jobs/${Uri.encodeComponent(job.id)}/$action$query',
      ),
    );
  }

  /// Runs job [id] now (notification "Retry"); same endpoint as [trigger].
  /// A run still going when the wait ends was started: it is not an error.
  Future<void> triggerById(String id) async {
    try {
      await client.apiPost(
        'cron/jobs/${Uri.encodeComponent(id)}/trigger${_query()}',
        timeout: triggerWait,
      );
    } on TimeoutException {
      return;
    }
  }

  /// Runs [job] now. Returns the job as the server left it when the run
  /// ended within [triggerWait]; throws [CronRunInProgress] when it is
  /// still running by then.
  Future<CronJob> trigger(CronJob job) async {
    try {
      return await _onOwner(
        job,
        (query) => client.apiPost(
          'cron/jobs/${Uri.encodeComponent(job.id)}/trigger$query',
          timeout: triggerWait,
        ),
      );
    } on TimeoutException {
      throw CronRunInProgress(job.id);
    }
  }

  /// Asks [job]'s live run to stop (Desktop `cancelCronJobRun`). The run
  /// books its cancelled attempt at its next cancel check, a second or two
  /// later, so callers read the job list until [cronStopOutcome] settles.
  /// The schedule is untouched. A 404 in the owner profile is a job that
  /// is gone.
  Future<CronCancelResult> cancelRun(CronJob job) async {
    final owner = ownerProfileOf(job);
    try {
      final data = await client.apiPost(
        'cron/jobs/${Uri.encodeComponent(job.id)}/cancel${_ownerQuery(job)}',
      );
      return CronCancelResult(
        cancelled: data['cancelled'] == true,
        executionId: data['execution_id']?.toString().trim() ?? '',
      );
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) throw CronJobNotFoundException(owner);
      rethrow;
    }
  }

  Future<CronJob> instantiateBlueprint(
    AutomationBlueprint blueprint,
    Map<String, String> values,
  ) async {
    final targetProfile = profile.isEmpty ? 'default' : profile;
    final data = await client.apiPost(
      'cron/blueprints/instantiate?profile=${Uri.encodeQueryComponent(targetProfile)}',
      body: {'blueprint': blueprint.key, 'values': values},
    );
    return CronJob.fromJson(data).withSourceProfile(targetProfile);
  }
}

String botRoutineName(String profile, String name, String prompt) {
  final owner = profile.trim().isEmpty ? 'default' : profile.trim();
  final prefix = '[bot:$owner] ';
  if (name.startsWith(prefix)) return name;
  final title = name.trim().isNotEmpty ? name.trim() : prompt.trim().split('\n').first;
  return '$prefix${title.length > 80 ? title.substring(0, 80) : title}';
}
