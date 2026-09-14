# Contributing to Hermes Console

Thanks for helping improve Hermes Console. Keep changes focused, reviewable,
and compatible with a privacy-first Android client for self-hosted Hermes
Agent instances.

## Before opening a pull request

1. Open or reference an issue for behavior changes and security-sensitive work.
2. Do not include credentials, private server addresses, user conversations,
   signing material, device identifiers, or screenshots from a real instance.
3. Do not add analytics, tracking, permissions, dependencies, endpoints, or
   cleartext network exceptions without an explicit design and security review.
4. Preserve upstream and third-party copyright and license notices.
5. Keep one logical change per pull request and use the existing commit style:
   `type(scope): short description`.

## Development checks

Use Flutter 3.47.x, its bundled Dart SDK, Java 17, and Android SDK 36.

```bash
flutter pub get
dart format path/to/each_changed_file.dart
flutter analyze
flutter test
```

Tests and analysis passing do not authorize publishing an APK, AAB, GitHub
Release, or Google Play release. Release signing material must remain outside
the repository.

## Licensing contributions

By submitting a contribution, you confirm that you have the right to submit it
and agree that it will be licensed under GPL-3.0-only. Third-party material must
identify its origin, copyright holder, license, and any required notices. Do not
submit material whose license is unknown or incompatible with redistribution.

## Security reports

Do not disclose vulnerabilities or credentials in a public issue. Follow
[SECURITY.md](SECURITY.md).
