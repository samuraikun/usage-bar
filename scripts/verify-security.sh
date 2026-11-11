#!/bin/bash
# 組み立てた UsageBar.app が、通信しない・読み取り範囲が狭いという性質を保っているかを確かめる。
#
#   scripts/verify-security.sh [--skip-runtime] [path/to/UsageBar.app]（省略時は build.noindex/UsageBar.app）
#   scripts/verify-security.sh --binary path/to/executable   実行ファイル 1 つに 3〜5 だけを行う
#                                                            （検査が通信するプログラムを NG にできるかの確認用）
#
# 確かめること:
#   1. アプリ本体が App Sandbox に入っていて、通信の権限（network.*）を持たない
#   2. ファイルの読み取り許可が想定した 4 つのディレクトリだけで、ほかの entitlement が無い
#   3. 2 つの実行ファイルが、通信・別プログラムの起動・動的な読み込みに使う API を参照していない
#   4. 2 つの実行ファイルに URL の文字列が埋め込まれていない
#   5. システム以外のライブラリを読み込んでいない
#   6. 指定したアプリが起動中で、サンドボックスの中で動き、ネットワークのソケットを開いていない
#      （--skip-runtime を付けたときだけ省く）
#
# 中継コマンド（usagebar-bridge）はサンドボックスの外で動くため、3 と 4 が通信しないことの主な根拠になる。
# 実行時に組み立てた URL までは見つけられないので、ソースの確認と合わせて使う。
#
# どの手順でも、検査に使う道具が失敗したら OK にせず NG にする。
set -uo pipefail

SKIP_RUNTIME=0
APP=""
SINGLE_BINARY=""
while (( $# > 0 )); do
  case "$1" in
    --skip-runtime) SKIP_RUNTIME=1 ;;
    --binary) shift; SINGLE_BINARY="${1:-}" ;;
    *) APP="$1" ;;
  esac
  shift
done
if [[ -n "$SINGLE_BINARY" ]]; then
  [[ -f "$SINGLE_BINARY" ]] || { echo "実行ファイルが見つかりません: $SINGLE_BINARY"; exit 2; }
fi
APP="${APP:-$(cd "$(dirname "$0")/.." && pwd)/build.noindex/UsageBar.app}"
failures=0
if [[ -n "$SINGLE_BINARY" ]]; then
  BINARIES=("$SINGLE_BINARY")
else
  APP="$(cd "$APP" 2>/dev/null && pwd -P)" || { echo "アプリが見つかりません"; exit 2; }
  MAIN="$APP/Contents/MacOS/UsageBar"
  BRIDGE="$APP/Contents/MacOS/usagebar-bridge"
  BINARIES=("$MAIN" "$BRIDGE")
fi

pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  NG   %s\n' "$1"; failures=$((failures + 1)); }
indent() { sed 's/^/         /'; }

for tool in codesign plutil nm strings otool lsof xcrun; do
  command -v "${tool}" >/dev/null || { echo "${tool} が見つかりません"; exit 2; }
done

if [[ -z "$SINGLE_BINARY" ]]; then
echo "== 対象: $APP"
[[ -x "${MAIN}" && -x "$BRIDGE" ]] || { echo "実行ファイルが見つかりません"; exit 2; }
echo "== 1-2. entitlements"
if ! codesign --verify --strict "$APP" 2>/dev/null; then
  fail "署名を検証できない（中身が署名後に変わっている）"
fi
if ! ENT_XML="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" || [[ -z "$ENT_XML" ]]; then
  fail "entitlements を読めない"
  ENT_XML='<plist version="1.0"><dict/></plist>'
fi
ENT="$(plutil -convert json -o - - <<<"$ENT_XML" 2>/dev/null)" || { fail "entitlements を JSON に変換できない"; ENT='{}'; }

if [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - <<<"$ENT" 2>/dev/null)" == "true" ]]; then
  pass "App Sandbox が有効"
else
  fail "App Sandbox が有効になっていない"
fi
if grep -qi 'network' <<<"$ENT"; then
  fail "通信に関する entitlement がある"
else
  pass "通信の権限（com.apple.security.network.*）が無い"
fi
EXPECTED='["/.claude/projects/","/.claude/usagebar/","/.codex/sessions/","/.codex/archived_sessions/"]'
ACTUAL="$(plutil -extract 'com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-only' json -o - - <<<"$ENT" 2>/dev/null | tr -d '\\')"
if [[ "$ACTUAL" == "$EXPECTED" ]]; then
  pass "読み取りを許可したパスは想定どおり: $ACTUAL"
else
  fail "読み取りを許可したパスが想定と違う: ${ACTUAL:-（取得できない）}"
fi
KEYS="$(grep -o '<key>[^<]*</key>' <<<"$ENT_XML" | sed 's/<[^>]*>//g' | sort | tr '\n' ' ')"
if [[ "$KEYS" == "com.apple.security.app-sandbox com.apple.security.temporary-exception.files.home-relative-path.read-only " ]]; then
  pass "entitlement はこの 2 つだけ"
else
  fail "想定外の entitlement がある: ${KEYS:-（取得できない）}"
fi
if BRIDGE_ENT="$(codesign -d --entitlements - --xml "$BRIDGE" 2>/dev/null)"; then
  if [[ -z "$BRIDGE_ENT" ]]; then pass "中継コマンドは entitlement を持たない"; else fail "中継コマンドに entitlement がある"; fi
else
  fail "中継コマンドの署名を読めない"
fi

else
  echo "== 対象: ${SINGLE_BINARY}（実行ファイル 1 つだけを検査）"
fi

echo "== 3. 通信・プログラムの起動・動的な読み込みに使う API を参照していないか"
# C の関数（先頭の _ を除いた完全一致）
C_SYMBOLS='socket|socketpair|connect|connectx|bind|listen|accept|send|sendto|sendmsg|recv|recvfrom|recvmsg|getaddrinfo|getnameinfo|gethostbyname|gethostbyname2|res_query|res_search|posix_spawn|posix_spawnp|execve|execv|execvp|execl|execlp|fork|vfork|system|popen|dlopen|dlsym|NSClassFromString|NSSelectorFromString|objc_getClass|objc_lookUpClass|nw_[a-z_]+|CFSocket[A-Za-z]*|CFStreamCreatePairWith[A-Za-z]*|CFReadStreamCreateWithFTPURL|CFURLCreateDataAndPropertiesFromResource|SCNetworkReachability[A-Za-z]*|SecItemCopyMatching'
# Swift / Objective-C の型やメソッド（部分一致）
NAME_PATTERNS='URLSession|NSURLConnection|NSURLDownload|CFHTTP|WKWebView|NWConnection|NWListener|NWBrowser|NWPathMonitor|URLRequest|NSTask|Foundation\.Process|contentsOf: Foundation\.URL|NSAppleScript|NSUserAppleScriptTask|XPCSession|NSXPCConnection'
for bin in "${BINARIES[@]}"; do
  name="$(basename "$bin")"
  if ! symbols="$(nm -u "$bin")" || [[ -z "$symbols" ]]; then
    fail "${name}: シンボルを読めない"; continue
  fi
  if ! demangled="$(xcrun swift-demangle --compact <<<"$symbols")" || [[ -z "$demangled" ]]; then
    fail "${name}: シンボルを読み替えられない"; continue
  fi
  hits="$( { sed 's/^_//' <<<"$symbols" | grep -Ex "$C_SYMBOLS"; grep -E "$NAME_PATTERNS" <<<"$demangled"; } | sort -u)"
  if [[ -z "$hits" ]]; then
    pass "${name}: 該当する API を参照していない（参照シンボル $(wc -l <<<"$symbols" | tr -d ' ') 個を確認）"
  else
    fail "${name}: 該当する API を参照している:"; indent <<<"$hits"
  fi
  # Objective-C のメソッドは文字列（セレクタ名）でしか残らないため、文字列でも調べる。
  if ! text="$(strings -a "$bin")"; then
    fail "${name}: 文字列を読めない"; continue
  fi
  selectors="$(grep -Eo '(openURL|openURLs|openApplicationAtURL|launchApplication|launchedTaskWithLaunchPath|dataWithContentsOfURL|initWithContentsOfURL|stringWithContentsOfURL|dataTaskWithURL|dataTaskWithRequest|sendSynchronousRequest|executeAndReturnError)[A-Za-z:]*' <<<"$text" | sort -u)"
  if [[ -z "$selectors" ]]; then
    pass "${name}: 通信やプログラムの起動に使うメソッド名を含まない"
  else
    fail "${name}: 通信やプログラムの起動に使うメソッド名を含む:"; indent <<<"$selectors"
  fi

  echo "== 4. URL の文字列（${name}）"
  urls="$(grep -Eio '(https?|wss?|ftp|file)://[^ "]*' <<<"$text" | sort -u)"
  if [[ -z "$urls" ]]; then
    pass "${name}: URL を含まない"
  else
    fail "${name}: URL を含む:"; indent <<<"$urls"
  fi
done

echo "== 5. 読み込むライブラリ"
for bin in "${BINARIES[@]}"; do
  name="$(basename "$bin")"
  if ! libs="$(otool -L "$bin")"; then
    fail "${name}: 読み込むライブラリを調べられない"; continue
  fi
  libs="$(tail -n +2 <<<"$libs" | awk '{print $1}')"
  [[ -n "$libs" ]] || { fail "${name}: ライブラリの一覧が空"; continue; }
  others="$(grep -Ev '^(/System/Library/|/usr/lib/)' <<<"$libs")"
  if [[ -z "$others" ]]; then
    pass "${name}: システムのライブラリだけ"
  else
    fail "${name}: システム以外のライブラリ:"; indent <<<"$others"
  fi
  if grep -qE 'Network\.framework|CFNetwork|WebKit|Security\.framework' <<<"$libs"; then
    fail "${name}: Network / CFNetwork / WebKit / Security のフレームワークを直接リンクしている"
  else
    pass "${name}: Network / CFNetwork / WebKit / Security のフレームワークを直接リンクしていない"
  fi
done

echo "== 6. 起動中のプロセス"
if [[ -n "$SINGLE_BINARY" ]]; then
  echo "  --   実行ファイル 1 つだけの検査のため省略"
elif (( SKIP_RUNTIME )); then
  echo "  --   --skip-runtime のため省略"
else
  PIDS="$(ps -axo pid=,comm= | awk -v target="${MAIN}" '$2 == target {print $1}')"
  if [[ -z "$PIDS" ]]; then
    fail "${MAIN} が起動していない（起動してから再実行するか、--skip-runtime を付ける）"
  elif ! command -v python3 >/dev/null; then
    fail "python3 が無いため、サンドボックスで動いているかを確かめられない"
  else
    for pid in $PIDS; do
      if ! sockets="$(lsof -nP -a -p "${pid}" -i 2>/dev/null; true)"; then
        fail "PID ${pid}: ソケットを調べられない"
      elif [[ -z "$sockets" ]]; then
        if lsof -nP -p "${pid}" >/dev/null 2>&1; then
          pass "PID ${pid}: ネットワークのソケットを開いていない"
        else
          fail "PID ${pid}: lsof でプロセスを調べられない"
        fi
      else
        fail "PID ${pid}: ネットワークのソケットを開いている:"; indent <<<"$sockets"
      fi
      state="$(python3 -I -c '
import ctypes, sys
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
lib.sandbox_check.restype = ctypes.c_int
lib.sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
print(lib.sandbox_check(int(sys.argv[1]), None, 0))
' "${pid}" 2>/dev/null)"
      if [[ "$state" == "1" ]]; then
        pass "PID ${pid}: App Sandbox の中で動いている"
      else
        fail "PID ${pid}: App Sandbox の中で動いていることを確かめられない（sandbox_check=${state:-失敗}）"
      fi
    done
  fi
fi

echo
if (( failures == 0 )); then
  echo "すべて確認できました。"
else
  echo "${failures} 件の問題があります。"
  exit 1
fi
