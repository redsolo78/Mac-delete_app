#!/bin/sh
# macOS App Uninstaller - POSIX /bin/sh
# Uso:
#   ./uninstall.sh "NomeApp"                # dry-run
#   ./uninstall.sh "NomeApp.app" --delete   # rimuove davvero
#   ./uninstall.sh --bundle-id com.vendor.App --delete
# Opzioni: --delete --force --kill --forget-pkg --bundle-id ID --verbose|-v --trace

set -eu

DELETE=0; FORCE=0; KILL=0; FORGET=0; VERBOSE=0
APP_ARG=""; BUNDLE_ID=""

log(){ printf '%s\n' "$*" >&2; }
vlog(){ [ "$VERBOSE" -eq 1 ] && log "$*"; }

# --- Argomenti ---
while [ $# -gt 0 ]; do
  case "$1" in
    --delete) DELETE=1 ;;
    --force) FORCE=1 ;;
    --kill) KILL=1 ;;
    --forget-pkg) FORGET=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --trace) set -x ;;
    --bundle-id) shift || { log "Manca valore per --bundle-id"; exit 1; }; BUNDLE_ID="$1" ;;
    -*) log "Opzione sconosciuta: $1"; exit 1 ;;
    *) APP_ARG="$1" ;;
  esac
  shift || true
done

[ -z "$APP_ARG" ] && [ -z "$BUNDLE_ID" ] && { log "Specifica un .app o --bundle-id <id>"; exit 1; }

APP_PATH=""
APP_NAME=""

# --- Trova .app ---
find_app_path() {
  NAME_NO_EXT="${APP_ARG%.app}"

  case "$APP_ARG" in
    *.app)
      [ -e "$APP_ARG" ] && APP_PATH="$(cd "$(dirname "$APP_ARG")" && pwd)/$(basename "$APP_ARG")" && return 0 || true
      ;;
  esac

  for base in "/Applications" "$HOME/Applications"; do
    [ -e "$base/$APP_ARG" ] && APP_PATH="$base/$APP_ARG" && return 0
    [ -e "$base/${APP_ARG}.app" ] && APP_PATH="$base/${APP_ARG}.app" && return 0
    [ -e "$base/${NAME_NO_EXT}.app" ] && APP_PATH="$base/${NAME_NO_EXT}.app" && return 0
  done

  # Varianti (es. "CodeRunner 4*.app")
  APP_PATH="$(/usr/bin/find /Applications "$HOME/Applications" -maxdepth 3 -type d -iname "${NAME_NO_EXT}*.app" -print -quit 2>/dev/null || true)"
  [ -n "$APP_PATH" ] && return 0

  # Spotlight fallback
  APP_PATH="$(/usr/bin/mdfind 'kMDItemContentTypeTree == "com.apple.application"' 2>/dev/null | /usr/bin/grep -i "/${NAME_NO_EXT}.*\.app\$" | head -n1 || true)"
  [ -n "$APP_PATH" ] && return 0

  return 1
}

if [ -n "$APP_ARG" ]; then
  find_app_path || true
fi

# Nome “umano”
if [ -n "$APP_PATH" ]; then
  APP_NAME="$(basename "$APP_PATH" .app)"
else
  APP_NAME="${APP_ARG%.app}"
fi

# Protezione app di sistema
if [ -n "$APP_PATH" ] && [ "${APP_PATH#/System/Applications/}" != "$APP_PATH" ]; then
  log "App di sistema: $APP_PATH — non la tocco."
  exit 1
fi

# --- Bundle ID ---
if [ -z "$BUNDLE_ID" ] && [ -n "$APP_PATH" ] && [ -e "$APP_PATH" ]; then
  BUNDLE_ID="$(/usr/bin/mdls -name kMDItemCFBundleIdentifier -raw "$APP_PATH" 2>/dev/null || true)"
  [ "$BUNDLE_ID" = "(null)" ] && BUNDLE_ID=""
fi
# Fallback AppleScript (può fallire, è ok)
if [ -z "$BUNDLE_ID" ] && [ -n "$APP_NAME" ]; then
  BUNDLE_ID="$(/usr/bin/osascript -e 'try' -e 'id of app "'"$APP_NAME"'"' -e 'on error' -e 'return ""' -e 'end try' 2>/dev/null || true)"
fi

USER_LIB="$HOME/Library"; SYS_LIB="/Library"

# --- Kill se richiesto ---
if [ "$KILL" -eq 1 ] && [ -n "$APP_NAME" ]; then
  vlog "[KILL] Chiudo $APP_NAME/n"
  /usr/bin/osascript -e 'tell application "'"$APP_NAME"'" to quit' >/dev/null 2>&1 || true
  sleep 1
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true
fi

# --- Costruisci lista candidati ---
CAND="$(/usr/bin/mktemp -t uninstall_cand)"
UNIQ="$(/usr/bin/mktemp -t uninstall_uniq)"
trap 'rm -f "$CAND" "$UNIQ" 2>/dev/null || true' EXIT

add_path(){ [ -e "$1" ] && printf '%s\n' "$1" >> "$CAND"; }
find_glob(){ [ -d "$1" ] || return 0; /usr/bin/find "$1" -maxdepth 1 -name "$2" -print 2>/dev/null >> "$CAND" || true; }
many_patterns(){ base="$1"; list="$2"; oldifs="$IFS"; IFS='|'
  for pat in $list; do find_glob "$base" "$pat"; done
  IFS="$oldifs"
}

# 1) .app stesso come primo candidato
[ -n "$APP_PATH" ] && add_path "$APP_PATH"

# 2) Tutto ciò che Spotlight collega al bundle id
if [ -n "$BUNDLE_ID" ]; then
  /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null >> "$CAND" || true
fi

# 3) Percorsi noti per residui (utente+sistema)
if [ -n "$BUNDLE_ID" ]; then
  many_patterns "$USER_LIB/Preferences"              "${BUNDLE_ID}.plist|*.${BUNDLE_ID}.plist"
  many_patterns "$USER_LIB/Preferences/ByHost"       "${BUNDLE_ID}.*.plist"
  many_patterns "$USER_LIB/Application Support"      "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$USER_LIB/Caches"                   "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$USER_LIB/Containers"               "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$USER_LIB/Group Containers"         "*${BUNDLE_ID}*"
  many_patterns "$USER_LIB/Saved Application State"  "${BUNDLE_ID}.savedState"
  many_patterns "$USER_LIB/Application Scripts"      "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$USER_LIB/Logs"                     "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$USER_LIB/WebKit"                   "${BUNDLE_ID}"
  many_patterns "$USER_LIB/Cookies"                  "${BUNDLE_ID}.binarycookies"

  many_patterns "$SYS_LIB/Preferences"               "${BUNDLE_ID}.plist"
  many_patterns "$SYS_LIB/Application Support"       "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$SYS_LIB/Caches"                    "${BUNDLE_ID}|${BUNDLE_ID}*"
  many_patterns "$SYS_LIB/LaunchAgents"              "${BUNDLE_ID}*.plist"
  many_patterns "$SYS_LIB/LaunchDaemons"             "${BUNDLE_ID}*.plist"
fi

# 4) Fallback su nome app
if [ -n "$APP_NAME" ]; then
  SAFE_NAME=$(printf '%s' "$APP_NAME" | tr ' ' '_')
  many_patterns "$USER_LIB/Preferences"              "*${APP_NAME}*.plist|*${SAFE_NAME}*.plist"
  many_patterns "$USER_LIB/Application Support"      "*${APP_NAME}*|*${SAFE_NAME}*"
  many_patterns "$USER_LIB/Caches"                   "*${APP_NAME}*|*${SAFE_NAME}*"
  many_patterns "$USER_LIB/Logs"                     "*${APP_NAME}*|*${SAFE_NAME}*"
  many_patterns "$SYS_LIB/Application Support"       "*${APP_NAME}*|*${SAFE_NAME}*"
  many_patterns "$SYS_LIB/Caches"                    "*${APP_NAME}*|*${SAFE_NAME}*"
fi

# Dedup
/usr/bin/awk 'NF{ if(!seen[$0]++){ print $0 } }' "$CAND" > "$UNIQ"

# --- Header chiaro ---
printf "=== TARGET ===\n"
[ -n "$APP_ARG" ]   && printf "Arg        : %s\n" "$APP_ARG"
[ -n "$APP_PATH" ]  && printf "App path   : %s\n" "$APP_PATH"
[ -n "$APP_NAME" ]  && printf "App name   : %s\n" "$APP_NAME"
[ -n "$BUNDLE_ID" ] && printf "Bundle ID  : %s\n" "$BUNDLE_ID"
printf "Mode       : %s (force=%s, kill=%s, forget_pkg=%s)\n\n" \
  "$( [ "$DELETE" -eq 1 ] && echo DELETE || echo DRY-RUN )" "$FORCE" "$KILL" "$FORGET"

if [ ! -s "$UNIQ" ]; then
  printf "Nessun file candidato trovato.\n"
  exit 0
fi

# --- Rimozione (niente subshell; no prompt se --force) ---
COUNT=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  case "$path" in
    /System/*) [ "$VERBOSE" -eq 1 ] && printf "[SKIP] %s (System)\n" "$path"; continue ;;
  esac

  if [ -d "$path" ]; then printf "DIR  %s\n" "$path"; else printf "FILE %s\n" "$path"; fi

  if [ "$DELETE" -eq 1 ]; then
    DOIT=1
    if [ "$FORCE" -ne 1 ]; then
      printf "  -> Cancello questo elemento? [y/N] "
      read ans || ans=""
      case "$ans" in y|Y) DOIT=1 ;; *) DOIT=0 ;; esac
    fi
    if [ "$DOIT" -eq 1 ]; then
      case "$path" in
        *.app|/Applications/*|$HOME/Applications/*)
          /usr/bin/osascript -e 'tell application "Finder" to delete POSIX file "'"$path"'"' >/dev/null 2>&1 \
            || /bin/rm -rf "$path" 2>/dev/null || /usr/bin/sudo /bin/rm -rf "$path"
          ;;
        /Library/*)
          /usr/bin/sudo /bin/rm -rf "$path"
          ;;
        *)
          /bin/rm -rf "$path"
          ;;
      esac
      COUNT=$((COUNT+1))
    fi
  fi
done < "$UNIQ"

if [ "$DELETE" -eq 1 ]; then
  printf "\n✔ Rimozioni eseguite: %d elemento/i.\n" "$COUNT"
else
  printf "\nℹ Dry-run completato. Aggiungi --delete per cancellare.\n"
fi

# --- pkg receipts ---
PATTERN="${BUNDLE_ID:-$APP_NAME}"
if [ -n "$PATTERN" ]; then
  printf "\n=== pkg receipts correlati (se presenti) ===\n"
  PKG_TMP="$(/usr/bin/mktemp -t uninstall_pkgs)"
  /usr/sbin/pkgutil --pkgs | /usr/bin/grep -Ei "$PATTERN" > "$PKG_TMP" || true
  if [ ! -s "$PKG_TMP" ]; then
    printf "(nessuno trovato)\n"
  else
    cat "$PKG_TMP"
    if [ "$FORGET" -eq 1 ]; then
      printf "\nEseguo pkgutil --forget...\n"
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && /usr/bin/sudo /usr/sbin/pkgutil --forget "$pkg" || true
      done < "$PKG_TMP"
    else
      printf "Aggiungi --forget-pkg per eseguire pkgutil --forget.\n"
    fi
  fi
  rm -f "$PKG_TMP" 2>/dev/null || true
fi
./uninstall.sh "CodeRunner" --kill --force --delete --verbose