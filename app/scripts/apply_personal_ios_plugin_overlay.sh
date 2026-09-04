#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
registrant="${1:-$ROOT_DIR/ios/Runner/GeneratedPluginRegistrant.m}"

[[ -f "$registrant" ]] || {
  echo "ERROR: Flutter plugin registrant is missing: $registrant" >&2
  exit 1
}

ruby - "$registrant" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
marker = 'OMI_PERSONAL_EXTERNAL_PLUGINS_DISABLED'
plugins = %w[
  FLTFirebaseCrashlyticsPlugin
  FLTFirebaseMessagingPlugin
  FLTGoogleSignInPlugin
  IntercomFlutterPlugin
  PosthogFlutterPlugin
  SignInWithApplePlugin
]

unless text.include?(marker)
  import_groups = [
    <<~'BLOCK'.chomp,
      #if __has_include(<firebase_crashlytics/FLTFirebaseCrashlyticsPlugin.h>)
      #import <firebase_crashlytics/FLTFirebaseCrashlyticsPlugin.h>
      #else
      @import firebase_crashlytics;
      #endif

      #if __has_include(<firebase_messaging/FLTFirebaseMessagingPlugin.h>)
      #import <firebase_messaging/FLTFirebaseMessagingPlugin.h>
      #else
      @import firebase_messaging;
      #endif
    BLOCK
    <<~'BLOCK'.chomp,
      #if __has_include(<google_sign_in_ios/FLTGoogleSignInPlugin.h>)
      #import <google_sign_in_ios/FLTGoogleSignInPlugin.h>
      #else
      @import google_sign_in_ios;
      #endif
    BLOCK
    <<~'BLOCK'.chomp,
      #if __has_include(<intercom_flutter/IntercomFlutterPlugin.h>)
      #import <intercom_flutter/IntercomFlutterPlugin.h>
      #else
      @import intercom_flutter;
      #endif
    BLOCK
    <<~'BLOCK'.chomp,
      #if __has_include(<posthog_flutter/PosthogFlutterPlugin.h>)
      #import <posthog_flutter/PosthogFlutterPlugin.h>
      #else
      @import posthog_flutter;
      #endif
    BLOCK
    <<~'BLOCK'.chomp,
      #if __has_include(<sign_in_with_apple/SignInWithApplePlugin.h>)
      #import <sign_in_with_apple/SignInWithApplePlugin.h>
      #else
      @import sign_in_with_apple;
      #endif
    BLOCK
  ]

  import_groups.each_with_index do |block, index|
    count = text.scan(Regexp.new(Regexp.escape(block))).length
    abort "ERROR: expected exactly one generated import block #{index + 1}, found #{count}" unless count == 1
    comment = index.zero? ? "// #{marker}: cloud-only native plugins are disabled.\n" : ''
    text.sub!(block, "#if !OMI_PERSONAL_LOCAL\n#{comment}#{block}\n#endif")
  end

  plugins.each do |plugin|
    line = "  [#{plugin} registerWithRegistrar:[registry registrarForPlugin:@\"#{plugin}\"]];"
    count = text.scan(line).length
    abort "ERROR: expected exactly one generated registration for #{plugin}, found #{count}" unless count == 1
    text.sub!(line, "#if !OMI_PERSONAL_LOCAL\n#{line}\n#endif")
  end

  File.write(path, text)
end

plugins.each do |plugin|
  registration = text.index("[#{plugin} registerWithRegistrar") or abort "ERROR: plugin registration missing: #{plugin}"
  guard = text.rindex('#if !OMI_PERSONAL_LOCAL', registration) or abort "ERROR: plugin guard missing: #{plugin}"
  close = text.index('#endif', guard) or abort "ERROR: plugin guard not closed: #{plugin}"
  abort "ERROR: plugin registration outside guard: #{plugin}" unless registration < close
end
RUBY

echo 'Personal Team native cloud-plugin overlay applied'
