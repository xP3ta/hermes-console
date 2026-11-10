import 'package:flutter/material.dart';

import 'in_app_browser_policy.dart';
import 'in_app_browser_screen.dart';

/// Opens an `http`/`https` link inside the app, in the in-app browser
/// ([InAppBrowserScreen], with its scheme and popup rules and its «Abrir en
/// el navegador» action). Its notch and Back return to where the link was
/// tapped; [backLabel] says where that is.
///
/// the owner's decision for Console 1.4.0, and a difference from Hermes Desktop,
/// which opens these links outside except its previews. Returns false,
/// opening nothing, for any other address: `mailto:`, `tel:` and intents
/// keep their own handling.
bool openWebLinkInApp(BuildContext context, Uri uri, {String? backLabel}) {
  if (!isBrowsableWebUri(uri)) return false;
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => InAppBrowserScreen(initialUrl: uri, backLabel: backLabel),
    ),
  );
  return true;
}
