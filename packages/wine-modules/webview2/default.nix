# WebView2 as winget-pkgs' manifest names it today. Evaluating this fetches the
# microsoft/winget-pkgs repository; webview2-pinned does not.
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
