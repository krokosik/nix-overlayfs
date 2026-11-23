# WebView2 as winget-pkgs' manifest names it today (this module was called
# `webview2` until the pinned layer took that name). Evaluating it fetches the
# microsoft/winget-pkgs repository and reads the manifest from a build result
# (import from derivation). Prefer `webview2`, or `webview2Release` for a
# specific version.
{
  runtime,
  overlayfsLib,
  managedRuntime ? "auto",
}:
overlayfsLib.mkWinpkgsPackage {
  inherit runtime managedRuntime;
  packageName = "Microsoft/EdgeWebView2Runtime";
  wineserverWaitTimeout = 60;
}
