import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';

/// Acerca de: identidad de la app, estado del proyecto, atribuciones y
/// acceso a las licencias open source. Las licencias viven aquí a propósito
/// — no son una pantalla protagonista.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Sitio oficial de la app (XPeta Lab). La política de privacidad enlaza a
  /// la misma página que declara la ficha de Google Play.
  static const _websiteUrl = 'https://hermes.xpetalab.dev';
  static const _privacyPolicyUrl = 'https://hermes.xpetalab.dev/privacy';
  static bool _appLicensesRegistered = false;

  static const _upstreamMitNotice = '''
hermes-android
https://github.com/rusty4444/hermes-android

The upstream project declares the MIT license in its README.

MIT License

Copyright (c) rusty4444 and hermes-android contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

  String _version = '…';

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception('launchUrl=false');
    } catch (e) {
      debugPrint('[about] no se pudo abrir $url: $e');
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).aboutLinkError)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_appLicensesRegistered) {
      LicenseRegistry.addLicense(() async* {
        final projectLicense = await rootBundle.loadString('LICENSE');
        yield LicenseEntryWithLineBreaks(const [
          'Hermes Console',
        ], projectLicense);
        yield const LicenseEntryWithLineBreaks([
          'hermes-android (upstream)',
        ], _upstreamMitNotice);
        final fontLicense = await rootBundle.loadString('assets/fonts/OFL.txt');
        yield LicenseEntryWithLineBreaks(const [
          'Inter',
          'Nunito',
          'Montserrat',
          'JetBrains Mono',
        ], fontLicense);
      });
      _appLicensesRegistered = true;
    }
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (e) {
      debugPrint(
        '[about] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      if (mounted) setState(() => _version = '—');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).aboutScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Identidad
          HermesCard(
            glow: true,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Image.asset(
                      'assets/branding/hermes_logo.webp',
                      width: 44,
                      height: 44,
                      // El master es 1024×1024; decodificar acotado al tamaño
                      // mostrado (×3 de DPR) ahorra ~4 MB de bitmap.
                      cacheWidth: 132,
                      cacheHeight: 132,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.auto_awesome,
                        size: 32,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'HERMES CONSOLE',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 3,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'v$_version',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.accentHover,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  Strings.of(context).aboutTagline,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        Strings.of(context).aboutReleaseStatus,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.accentHover,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Licencias y atribuciones
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.description_outlined,
                    color: colors.textSecondary,
                  ),
                  title: Text(Strings.of(context).aboutLicensesTitle),
                  subtitle: Text(
                    Strings.of(context).aboutThirdParty,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: colors.textDisabled,
                  ),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Hermes Console',
                    applicationVersion: 'v$_version',
                  ),
                ),
                Divider(
                  height: 0,
                  indent: 16,
                  endIndent: 16,
                  color: colors.divider,
                ),
                ListTile(
                  leading: Icon(
                    Icons.fork_right_outlined,
                    color: colors.textSecondary,
                  ),
                  title: Text(Strings.of(context).aboutBaseProject),
                  subtitle: Text(
                    Strings.of(context).aboutAttributions,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Privacidad
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(
                Icons.visibility_off_outlined,
                color: colors.success,
              ),
              title: Text(Strings.of(context).aboutPrivacyTitle),
              subtitle: Text(
                Strings.of(context).aboutPrivacyBody,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          // Enlaces oficiales: web y política de privacidad. Solo URLs https
          // propias y constantes (sin entrada del usuario).
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.language_outlined,
                    color: colors.textSecondary,
                  ),
                  title: Text(Strings.of(context).aboutWebsiteTitle),
                  subtitle: Text(
                    Strings.of(context).aboutWebsiteSub,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  trailing: Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                  onTap: () => _openLink(_websiteUrl),
                ),
                Divider(
                  height: 0,
                  indent: 16,
                  endIndent: 16,
                  color: colors.divider,
                ),
                ListTile(
                  leading: Icon(
                    Icons.policy_outlined,
                    color: colors.textSecondary,
                  ),
                  title: Text(Strings.of(context).aboutPrivacyPolicyTitle),
                  subtitle: Text(
                    Strings.of(context).aboutPrivacyPolicySub,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  trailing: Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                  onTap: () => _openLink(_privacyPolicyUrl),
                ),
              ],
            ),
          ),
          // Nota de compatibilidad
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
            child: Text(
              Strings.of(context).aboutUnofficial,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: colors.textDisabled,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
