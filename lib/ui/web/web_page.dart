import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:custed2/ui/theme.dart';
import 'package:custed2/core/extension/stringx.dart';
import 'package:custed2/core/util/build_mode.dart';
import 'package:custed2/core/webview/addon.dart';
import 'package:custed2/core/webview/user_agent.dart';
import 'package:custed2/locator.dart';
import 'package:custed2/ui/web/web_progress.dart';
import 'package:custed2/ui/widgets/bottom_sheet.dart';
import 'package:custed2/ui/widgets/dark_mode_filter.dart';
import 'package:custed2/ui/widgets/placeholder/placeholder.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class WebPage extends StatefulWidget {
  WebPage({this.defaultUrl});

  final title = '';
  final canGoBack = true;
  final String defaultUrl;
  final String userAgent = null;

  @override
  WebPageState createState() => WebPageState();
}

class WebPageState extends State<WebPage> {
  InAppWebViewController controller;

  WebProgressController progressController = WebProgressController();
  Widget overlay;

  List<WebviewAddon> activeAddons = [];
  List<Widget> addonWidgets = [];

  bool isBusy = false;
  Widget replace;

  final addons = <WebviewAddon>[];

  void onCreated() {}

  void onPageStarted(String url) {}

  void onPageFinished(String url) {}

  void onDownloadStart(String url) {}

  Future<bool> onNavigate(ShouldOverrideUrlLoadingRequest request) {
    return Future.value(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: theme.webviewNavBarColor,
        actionsForegroundColor: theme.navBarActionsColor,
        middle: Text(
          widget.title,
          style: TextStyle(color: theme.navBarActionsColor),
        ),
        trailing: isBusy ? _buildIndicator(context) : null,
      ),
      child: SafeArea(
        child: _buildWebviewWithAddons(context),
      ),
    );
  }

  Widget _buildWebviewWithAddons(BuildContext context) {
    final theme = AppTheme.of(context);

    if (replace != null) return replace;

    Widget result = DarkModeFilter(
      child: _buildWebview(context),
      level: 170,
    );

    result = Stack(
      children: <Widget>[
        result,
        if (widget.canGoBack)
          Positioned(
            right: 20,
            bottom: 20,
            child: Container(
              width: 50,
              height: 50,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                color: theme.webviewNavBarColor,
                child: Icon(
                  material.Icons.arrow_back,
                  color: CupertinoColors.white,
                  size: 30,
                ),
                onPressed: () async {
                  // Prevent user from go back to the 'loading...' page.
                  final history = await controller.getCopyBackForwardList();
                  if (history.currentIndex <= 1) return;
                  controller?.goBack();
                },
              ),
            ),
          ),
        if (overlay != null) overlay,
      ],
    );

    if (addonWidgets.isNotEmpty) {
      result = BottomSheet(
        child: result,
        sheet: Container(
          padding: EdgeInsets.all(5),
          child: Column(children: addonWidgets),
        ),
      );
    }

    return result;
  }

  Widget _buildWebview(BuildContext context) {
    return InAppWebView(
      initialOptions: InAppWebViewWidgetOptions(
        crossPlatform: InAppWebViewOptions(
          debuggingEnabled: true,
          useShouldOverrideUrlLoading: true,
          useOnDownloadStart: true,
          userAgent: widget.userAgent ?? UserAgent.defaultUA,
        ),
      ),
      onWebViewCreated: (controller) {
        this.controller = controller;
        this.overlayWith(WebProgressLayer(0, 1));
        onCreated();
      },
      onLoadStart: (controller, url) {
        print('INCAT load: $url');
        setState(() => isBusy = true);
        addonOnLoadStart(controller, url);
        this.overlayWith(WebProgress(progressController));
        onPageStarted(url);
      },
      onLoadStop: (controller, url) async {
        setState(() => isBusy = false);
        await addonOnLoadStop(controller, url);
        onPageFinished(url);

        // 防止多次重定向出现抖动
        await Future.delayed(Duration(milliseconds: 100));
        final stillLoading = await controller.isLoading();
        if (stillLoading) return;
        if (url == 'about:blank') return;
        this.overlayWith(null);
      },
      onLoadError: (controller, url, code, message) {
        replaceWith(PlaceholderWidget(text: '加载失败[$code]'));
        print('INCAT loadError: $url, $code, $message');
      },
      shouldOverrideUrlLoading: (controller, request) async {
        print('INCAT redirect: ${request.url}');
        final allow = await onNavigate(request);
        return allow
            ? ShouldOverrideUrlLoadingAction.ALLOW
            : ShouldOverrideUrlLoadingAction.CANCEL;
      },
      onProgressChanged: (controller, percent) {
        print(percent);
        progressController?.update(percent, 100);
      },
      onDownloadStart: (controller, url) {
        print('INCAT download: $url');
        onDownloadStart(url);
      },
      onConsoleMessage: (controller, message) {
        if (BuildMode.isDebug) print('|WEBVIEW|: ' + message.message);
      },
    );
  }

  void addonOnLoadStart(InAppWebViewController controller, String url) {
    final uri = url.toUri();
    activeAddons = addons.where((addon) => addon.shouldActivate(uri)).toList();
    addonBuildWidgets(controller, url);
    for (var addon in activeAddons) {
      addon.onPageStarted(controller, url);
    }
  }

  Future<void> addonOnLoadStop(
      InAppWebViewController controller, String url) async {
    for (var addon in activeAddons) {
      await addon.onPageFinished(controller, url);
    }
  }

  void addonBuildWidgets(InAppWebViewController controller, String url) {
    final widgets = <Widget>[];
    for (var addon in activeAddons) {
      final widget = addon.build(controller, url);
      if (widget != null) widgets.add(widget);
    }
    // setState(() => addonWidgets = widgets);
  }

  Widget _buildIndicator(BuildContext context) {
    return CupertinoTheme(
      data: CupertinoThemeData(brightness: Brightness.dark),
      child: CupertinoActivityIndicator(),
    );
  }

  Future<void> loadCookieFor(String url) async {
    final cookies = locator<PersistCookieJar>().loadForRequest(url.toUri());
    print(cookies);
    for (var cookie in cookies) {
      final domain = cookie.domain == null
          ? null
          : cookie.domain.startsWith('.') ? cookie.domain : '.' + cookie.domain;
      await CookieManager.instance().setCookie(
        url: url,
        name: cookie.name,
        value: cookie.value,
        domain: domain,
        path: cookie.path ?? '/',
        maxAge: cookie.maxAge,
        isSecure: cookie.secure,
      );
    }
  }

  void replaceWith(Widget widget) {
    setState(() => replace = widget);
  }

  void overlayWith(Widget widget) {
    setState(() => overlay = widget);
  }

  static String generateInitPage() {
    final template = '''
      <!DOCTYPE html><html>
      <head>
        <title>Loading</title>
        <script>
          (function() {
            var n = 0;
            var d = ['', '.', '..', '...'];
            setInterval(function() {
              document.querySelector('.loading').innerHTML = 'Loading' + d[n % d.length];
              n++;
            }, 100);
          })();
        </script>
      </head>
      <body>
        <div class="loading">
          Loading...
        </div>
      </body>
      </html>
    ''';
    final contentBase64 = base64.encode(utf8.encode(template));
    return 'data:text/html;base64,$contentBase64';
  }
}
