import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
        as Map<String, dynamic>;

String _source(String path) => File(path).readAsStringSync();

void _expectLocalized(
  Map<String, String> expectedEn,
  Map<String, String> expectedEs,
) {
  final en = _arb('en');
  final es = _arb('es');
  for (final entry in expectedEn.entries) {
    expect(en[entry.key], entry.value, reason: 'English ${entry.key}');
    expect(
      es[entry.key],
      expectedEs[entry.key],
      reason: 'Spanish ${entry.key}',
    );
  }
}

void main() {
  test('LiteRT Store and catalog expose natural English and correct Spanish', () {
    const en = {
      'litertStoreTitle': 'GPU model store',
      'litertStoreIntro':
          'Models in .litertlm format that OlliteRT runs on your phone’s GPU/NPU. Downloads happen in OlliteRT (from its store); here you can see which models fit your phone, open them for download, and tap “Use” to make an already served model active in Hermes.',
      'litertStoreRecommended': 'Recommended',
      'litertStoreInUseLower': 'in use',
      'litertStoreDownloaded': 'downloaded',
      'litertStoreDownload': 'Download',
      'litertStoreInUse': 'In use',
      'litertStoreUse': 'Use',
      'litertStoreStartHint':
          'Download and start it in OlliteRT before using it.',
      'litertStoreFits': 'fits',
      'litertStoreTight': 'tight',
      'litertStoreTooBig': 'doesn’t fit',
      'litertStoreOpenError': 'Could not open {url}',
      'litertNoteRecommended': 'Recommended for most phones',
      'litertNoteHighEnd': 'More capable; for high-end phones (12 GB+)',
      'litertNoteLightweight': 'Very lightweight; runs on almost any phone',
      'litertNoteDistilledReasoner': 'Distilled reasoning model',
    };
    const es = {
      'litertStoreTitle': 'Tienda de modelos GPU',
      'litertStoreIntro':
          'Modelos .litertlm que OlliteRT corre en la GPU/NPU del móvil. La descarga ocurre dentro de OlliteRT (su tienda); aquí ves cuáles caben en tu móvil, los abres para descargar, y «Usar» fija el que ya esté servido como modelo activo de Hermes.',
      'litertStoreRecommended': 'Recomendado',
      'litertStoreInUseLower': 'en uso',
      'litertStoreDownloaded': 'descargado',
      'litertStoreDownload': 'Descargar',
      'litertStoreInUse': 'En uso',
      'litertStoreUse': 'Usar',
      'litertStoreStartHint':
          'Descárgalo y arráncalo en OlliteRT para poder usarlo.',
      'litertStoreFits': 'cabe',
      'litertStoreTight': 'justo',
      'litertStoreTooBig': 'no cabe',
      'litertStoreOpenError': 'No se pudo abrir {url}',
      'litertNoteRecommended': 'Recomendado para la mayoría de móviles',
      'litertNoteHighEnd': 'Más capaz, para gama alta (12 GB+)',
      'litertNoteLightweight': 'Muy ligero, arranca en casi cualquier móvil',
      'litertNoteDistilledReasoner': 'Razonador destilado',
    };
    _expectLocalized(en, es);

    final screen = _source('lib/core/screens/litert_store_screen.dart');
    final catalog = _source('lib/core/data/litert_catalog.dart');
    for (final key in en.keys.where((key) => key.startsWith('litertStore'))) {
      expect(screen, contains('.$key'));
    }
    for (final key in en.keys.where((key) => key.startsWith('litertNote'))) {
      expect(screen, contains('.$key'));
    }
    expect(catalog, isNot(contains('Recomendado para la mayoría de móviles')));
    expect(catalog, isNot(contains('Más capaz, para gama alta')));
    expect(catalog, isNot(contains('Muy ligero, arranca')));
    expect(catalog, isNot(contains('Razonador destilado')));
  });

  test('Models reachable copy is localized in English and Spanish', () {
    const en = {
      'mdlNoActiveModelTitle': 'No model configured',
      'mdlNoActiveModelBody':
          'This server does not have credentials for an AI provider yet. Configure one below to start using it.',
      'mdlEditProvider': 'Edit provider',
      'mdlConfigNeedsDashboard': 'Requires the Dashboard to configure',
      'mdlDashboardOfflineSuffix': 'no Dashboard connection',
    };
    const es = {
      'mdlNoActiveModelTitle': 'Sin modelo configurado',
      'mdlNoActiveModelBody':
          'Este servidor aún no tiene ningún proveedor de IA con credencial. Configura uno más abajo para poder usarlo.',
      'mdlEditProvider': 'Editar proveedor',
      'mdlConfigNeedsDashboard': 'Requiere el Dashboard para configurar',
      'mdlDashboardOfflineSuffix': 'sin conexión al Dashboard',
    };
    _expectLocalized(en, es);

    final source = _source('lib/core/screens/models_screen.dart');
    for (final key in en.keys) {
      expect(source, contains('.$key'));
    }
    expect(source, isNot(contains("'Sin modelo configurado'")));
    expect(source, isNot(contains("'Editar proveedor'")));
    expect(source, isNot(contains("'Requiere el Dashboard para configurar'")));
    expect(source, isNot(contains('· sin conexión al Dashboard')));
  });

  test('local Runs copy is localized in English and Spanish', () {
    const en = {
      'runsLocalRunning': 'Running on the local agent…',
      'runsLocalBridgeUnavailable':
          'Could not connect to the local agent (Mobile Bridge). Start the agent and try again.',
    };
    const es = {
      'runsLocalRunning': 'Ejecutando en el agente local…',
      'runsLocalBridgeUnavailable':
          'No se pudo conectar con el agente local (Mobile Bridge). Arranca el agente y reintenta.',
    };
    _expectLocalized(en, es);

    final source = _source('lib/core/screens/runs_screen.dart');
    for (final key in en.keys) {
      expect(source, contains('.$key'));
    }
    expect(source, isNot(contains("'Ejecutando en el agente local…'")));
    expect(source, isNot(contains("'No se pudo conectar con el agente local")));
  });

  test('Task Center Mobile Bridge copy is localized in English and Spanish', () {
    const en = {
      'runsLocalRunning': 'Running on the local agent…',
      'runsLocalBridgeUnavailable':
          'Could not connect to the local agent (Mobile Bridge). Start the agent and try again.',
    };
    const es = {
      'runsLocalRunning': 'Ejecutando en el agente local…',
      'runsLocalBridgeUnavailable':
          'No se pudo conectar con el agente local (Mobile Bridge). Arranca el agente y reintenta.',
    };
    _expectLocalized(en, es);

    final source = _source('lib/core/screens/task_center_screen.dart');
    for (final key in en.keys) {
      expect(source, contains('.$key'));
    }
    expect(source, isNot(contains("'Ejecutando en el agente local…'")));
    expect(source, isNot(contains("'No se pudo conectar con el agente local")));
  });
}
