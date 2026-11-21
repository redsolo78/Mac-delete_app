#!/bin/sh
# macOS App Uninstaller - POSIX /bin/sh  (v2.2)
#
# Accesso completo al disco (FDA):
#   con --delete lo script richiede che il terminale abbia l'Accesso completo al disco;
#   se manca mostra un popup e si ferma. A fine esecuzione (anche su errore o Ctrl+C)
#   il permesso viene SEMPRE revocato con tccutil, salvo --keep-fda.
#
# Uso:
#   ./uninstall.sh "NomeApp"                      # dry-run (default, non cancella nulla)
#   ./uninstall.sh "NomeApp.app" --delete         # rimuove chiedendo conferma per ogni elemento
#   ./uninstall.sh "NomeApp" --delete --force     # rimuove senza conferma i match per bundle ID
#   ./uninstall.sh --bundle-id com.vendor.App --delete
#
# Opzioni:
#   --delete        rimuove davvero (senza: dry-run)
#   --force         niente conferma per i match "sicuri" (app + bundle ID);
#                   i match per NOME e le altre copie dell'app chiedono SEMPRE conferma
#   --kill          chiude l'app se in esecuzione prima di rimuoverla
#   --forget-pkg    esegue pkgutil --forget sulle ricevute trovate
#   --bundle-id ID  usa questo bundle ID invece di ricavarlo dall'app
#   --verbose, -v   output dettagliato
#   --keep-fda      non revocare a fine script l'Accesso completo al disco del terminale
#   --trace         set -x
#   --help, -h      questo aiuto

# Niente "set -e": un singolo rm fallito (es. ~/Library/Containers protetto)
# non deve interrompere la rimozione a metà. Gli errori sono gestiti uno per uno.
set -u

DELETE=0; FORCE=0; KILL=0; FORGET=0; VERBOSE=0; KEEP_FDA=0
FDA_REVOKE=0
CAND=""; UNIQ=""; MATCHES=""; PKG_TMP=""
APP_ARG=""; BUNDLE_ID=""
MIN_NAME_LEN=4          # sotto questa lunghezza niente ricerca per nome (troppo generica)
TAB="$(printf '\t')"

log(){ printf '%s\n' "$*" >&2; }
vlog(){ [ "$VERBOSE" -eq 1 ] || return 0; log "$*"; }
die(){ log "Errore: $*"; exit 1; }
usage(){ /usr/bin/sed -n '2,28p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; }

# --- Argomenti ---
while [ $# -gt 0 ]; do
  case "$1" in
    --delete) DELETE=1 ;;
    --force) FORCE=1 ;;
    --kill) KILL=1 ;;
    --forget-pkg) FORGET=1 ;;
    --keep-fda) KEEP_FDA=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --trace) set -x ;;
    --help|-h) usage; exit 0 ;;
    --bundle-id)
      [ $# -ge 2 ] || die "manca il valore per --bundle-id"
      shift; BUNDLE_ID="$1" ;;
    -*) die "opzione sconosciuta: $1 (vedi --help)" ;;
    *)
      [ -z "$APP_ARG" ] || die "specifica una sola app (trovati '$APP_ARG' e '$1')"
      APP_ARG="$1" ;;
  esac
  shift
done

[ -n "$APP_ARG" ] || [ -n "$BUNDLE_ID" ] || die "specifica un .app o --bundle-id <id> (vedi --help)"
[ "$(/usr/bin/uname -s)" = "Darwin" ] || die "questo script funziona solo su macOS"

# Niente sudo: con sudo $HOME diventa /var/root e i residui in ~/Library non si trovano.
# Lo script usa sudo da solo, e solo per i file in /Library.
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  die "non lanciarlo con sudo (\$HOME sarebbe ${HOME:-?}, non la tua home). Usa: ./$(basename "$0") ... — chiederà la password solo se serve."
fi

# Bundle ID: solo caratteri ammessi, così è sicuro usarlo in glob e query
valid_bundle_id(){
  case "$1" in
    ""|*[!A-Za-z0-9.-]*|.*|*.) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}
[ -z "$BUNDLE_ID" ] || valid_bundle_id "$BUNDLE_ID" || die "bundle ID non valido: $BUNDLE_ID"

# --- Accesso completo al disco (FDA) del terminale ---
# Il permesso appartiene all'app terminale che lancia lo script (Terminale, iTerm2...).
term_bundle_id(){
  tb="${__CFBundleIdentifier:-}"
  if [ -z "$tb" ]; then
    case "${TERM_PROGRAM:-}" in
      Apple_Terminal) tb="com.apple.Terminal" ;;
      iTerm.app)      tb="com.googlecode.iterm2" ;;
      ghostty)        tb="com.mitchellh.ghostty" ;;
      WarpTerminal)   tb="dev.warp.Warp-Stable" ;;
      vscode)         tb="com.microsoft.VSCode" ;;
    esac
  fi
  valid_bundle_id "$tb" || return 1
  printf '%s' "$tb"
}

term_app_name(){
  case "$(term_bundle_id 2>/dev/null)" in
    com.apple.Terminal)     echo "Terminale" ;;
    com.googlecode.iterm2)  echo "iTerm2" ;;
    com.mitchellh.ghostty)  echo "Ghostty" ;;
    dev.warp.Warp-Stable)   echo "Warp" ;;
    com.microsoft.VSCode)   echo "Visual Studio Code" ;;
    *)                      echo "il tuo terminale" ;;
  esac
}

# Si legge solo con l'Accesso completo al disco
has_fda(){
  /usr/bin/head -c 1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1 && return 0
  /bin/ls "$HOME/Library/Safari" >/dev/null 2>&1 && return 0
  return 1
}

FDA_PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

require_fda(){
  has_fda && return 0
  tn="$(term_app_name)"
  msg="Per cancellare i dati delle app, $tn ha bisogno dell'Accesso completo al disco.

1. Impostazioni > Privacy e sicurezza > Accesso completo al disco
2. Attiva $tn (se non c'è, aggiungilo con +)
3. Esci da $tn (Cmd+Q), riaprilo e rilancia lo script.

Alla fine lo script toglierà il permesso da solo."
  log ""
  log "STOP: $tn non ha l'Accesso completo al disco."
  log "$msg"
  btn="$(/usr/bin/osascript \
          -e 'on run argv' \
          -e 'display dialog (item 1 of argv) with title "macOS App Uninstaller" buttons {"Annulla", "Apri Impostazioni"} default button 2 cancel button 1 with icon caution' \
          -e 'return button returned of result' \
          -e 'end run' "$msg" 2>/dev/null)" || btn=""
  if [ "$btn" = "Apri Impostazioni" ]; then
    /usr/bin/open "$FDA_PANE" >/dev/null 2>&1 || true
  fi
  exit 3
}

# shellcheck disable=SC2329  # chiamata dal trap EXIT
revoke_fda(){
  [ "$FDA_REVOKE" -eq 1 ] || return 0
  FDA_REVOKE=0
  if [ "$KEEP_FDA" -eq 1 ]; then
    log ""
    log "Nota: --keep-fda, l'Accesso completo al disco resta attivo per $(term_app_name)."
    return 0
  fi
  if ! tb="$(term_bundle_id)"; then
    log ""
    log "Attenzione: non riconosco il terminale, non posso revocare l'Accesso completo al disco."
    log "  Toglilo a mano: Impostazioni > Privacy e sicurezza > Accesso completo al disco."
    return 0
  fi
  if /usr/bin/tccutil reset SystemPolicyAllFiles "$tb" >/dev/null 2>&1; then
    log ""
    log "Accesso completo al disco revocato per $(term_app_name) ($tb)."
  else
    log ""
    log "Attenzione: tccutil non è riuscito a revocare l'accesso per $tb."
    log "  Toglilo a mano: Impostazioni > Privacy e sicurezza > Accesso completo al disco."
    /usr/bin/open "$FDA_PANE" >/dev/null 2>&1 || true
  fi
}

# shellcheck disable=SC2329  # chiamata dal trap EXIT
cleanup(){
  rm -f "$CAND" "$UNIQ" "$MATCHES" "$PKG_TMP" 2>/dev/null
  revoke_fda
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$DELETE" -eq 1 ]; then
  require_fda
elif ! has_fda; then
  log "Nota: senza Accesso completo al disco il dry-run può non vedere tutto (es. l'app nel Cestino)."
fi
# Da qui in poi il permesso viene revocato a fine script, qualunque cosa succeda
FDA_REVOKE=1

# C'è un terminale per chiedere conferma? (lo stdin del ciclo è il file dei candidati)
HAS_TTY=0
if (: </dev/tty) 2>/dev/null; then HAS_TTY=1; fi

ask(){
  printf '  -> %s [y/N] ' "$1" >/dev/tty
  read -r ans </dev/tty || ans=""
  case "$ans" in y|Y|s|S) return 0 ;; esac
  return 1
}

plist_get(){  # $1 = .app, $2 = chiave
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

CAND="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/uninstall_cand.XXXXXX")" || die "mktemp fallito"
UNIQ="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/uninstall_uniq.XXXXXX")" || die "mktemp fallito"
MATCHES="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/uninstall_match.XXXXXX")" || die "mktemp fallito"
PKG_TMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/uninstall_pkgs.XXXXXX")" || die "mktemp fallito"

APP_PATH=""; APP_NAME=""; APP_EXEC=""

# --- Trova .app (se ci sono più corrispondenze NON sceglie a caso) ---
pick_single(){  # legge $MATCHES; 0 = un solo risultato in APP_PATH
  n="$(/usr/bin/awk 'NF' "$MATCHES" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [ "$n" -eq 0 ] && return 1
  if [ "$n" -gt 1 ]; then
    log "Più app corrispondono a '$APP_ARG':"
    /usr/bin/awk 'NF{print "  " $0}' "$MATCHES" >&2
    die "indica il percorso esatto del .app o usa --bundle-id"
  fi
  APP_PATH="$(/usr/bin/awk 'NF' "$MATCHES")"
  return 0
}

find_app_path(){
  NAME_NO_EXT="${APP_ARG%.app}"
  NAME_NO_EXT="${NAME_NO_EXT%/}"

  # Percorso esplicito
  case "$APP_ARG" in
    */*|*.app)
      if [ -d "$APP_ARG" ]; then
        APP_PATH="$(cd "$(dirname "$APP_ARG")" && pwd)/$(basename "$APP_ARG")"
        return 0
      fi ;;
  esac

  # Nome esatto
  for base in "/Applications" "/Applications/Utilities" "$HOME/Applications"; do
    [ -d "$base/${NAME_NO_EXT}.app" ] && { APP_PATH="$base/${NAME_NO_EXT}.app"; return 0; }
  done

  # Varianti (es. "CodeRunner 4.app"), senza entrare dentro altri bundle
  : > "$MATCHES"
  for base in "/Applications" "$HOME/Applications"; do
    [ -d "$base" ] || continue
    /usr/bin/find "$base" -maxdepth 2 -type d -iname "${NAME_NO_EXT}*.app" -prune -print 2>/dev/null >> "$MATCHES"
  done
  pick_single && return 0

  # Spotlight: il nome del bundle deve iniziare con il nome cercato
  /usr/bin/mdfind 'kMDItemContentTypeTree == "com.apple.application-bundle"' 2>/dev/null \
    | /usr/bin/awk -v n="$NAME_NO_EXT" '
        { p=$0; b=p; sub(/.*\//, "", b) }
        tolower(substr(b, 1, length(n))) == tolower(n) && b ~ /\.app$/ && p !~ /\.app\// { print p }
      ' > "$MATCHES"
  pick_single && return 0

  # Cestino: l'app potrebbe esserci già finita (anche rinominata, es. "App 10.23.45.app").
  # Senza "Accesso completo al disco" il Terminale non può leggere ~/.Trash: errori ignorati.
  : > "$MATCHES"
  if [ -d "$HOME/.Trash" ]; then
    /usr/bin/find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -type d -iname "${NAME_NO_EXT}*.app" -print 2>/dev/null >> "$MATCHES"
  fi
  pick_single && return 0

  return 1
}

IN_TRASH=0
if [ -n "$APP_ARG" ]; then
  find_app_path || log "Attenzione: nessun .app trovato per '$APP_ARG' (cerco comunque i residui)."
fi
case "$APP_PATH" in
  "$HOME"/.Trash/*) IN_TRASH=1 ;;
esac

if [ -n "$APP_PATH" ]; then
  case "$APP_PATH" in
    *.app) ;;
    *) die "non è un bundle .app: $APP_PATH" ;;
  esac
  case "$APP_PATH" in
    /System/*) die "app di sistema: $APP_PATH — non la tocco." ;;
  esac
  APP_NAME="$(basename "$APP_PATH" .app)"
  if [ "$IN_TRASH" -eq 1 ]; then
    # Nel Cestino il nome può avere un suffisso: usa quello del bundle o quello passato
    APP_NAME="$(plist_get "$APP_PATH" CFBundleName || true)"
    [ -n "$APP_NAME" ] || APP_NAME="$(basename "${APP_ARG%.app}")"
    log "L'app è già nel Cestino ($APP_PATH): la uso solo per ricavare il bundle ID."
  fi
  APP_EXEC="$(plist_get "$APP_PATH" CFBundleExecutable || true)"
elif [ -n "$APP_ARG" ]; then
  APP_NAME="$(basename "${APP_ARG%.app}")"
fi

# --- Bundle ID (Info.plist > Spotlight; niente AppleScript che può lanciare l'app) ---
if [ -z "$BUNDLE_ID" ] && [ -n "$APP_PATH" ]; then
  BUNDLE_ID="$(plist_get "$APP_PATH" CFBundleIdentifier || true)"
  if [ -z "$BUNDLE_ID" ]; then
    BUNDLE_ID="$(/usr/bin/mdls -name kMDItemCFBundleIdentifier -raw "$APP_PATH" 2>/dev/null || true)"
    [ "$BUNDLE_ID" = "(null)" ] && BUNDLE_ID=""
  fi
  if [ -n "$BUNDLE_ID" ] && ! valid_bundle_id "$BUNDLE_ID"; then
    log "Attenzione: bundle ID strano ($BUNDLE_ID), lo ignoro."
    BUNDLE_ID=""
  fi
fi

case "$BUNDLE_ID" in
  com.apple.*)
    # App Apple installate in /Applications (Pages, Keynote...) si possono togliere,
    # ma i loro residui in ~/Library sono spesso condivisi: avviso.
    log "Attenzione: app Apple ($BUNDLE_ID). Controlla bene la lista prima di cancellare." ;;
esac

[ -n "$APP_PATH" ] || [ -n "$BUNDLE_ID" ] || [ -n "$APP_NAME" ] || die "niente da cercare"

if [ -z "$BUNDLE_ID" ]; then
  log "Attenzione: bundle ID sconosciuto, cerco solo per nome (risultati parziali)."
  log "  Se l'app è già stata cancellata, rilancia con --bundle-id <id>, ad esempio:"
  log "    ls ~/Library/Containers | grep -i '${APP_NAME:-nome}'"
fi

USER_LIB="$HOME/Library"; SYS_LIB="/Library"

# --- App in esecuzione? ---
PROC="${APP_EXEC:-$APP_NAME}"
if [ -n "$PROC" ] && /usr/bin/pgrep -x "$PROC" >/dev/null 2>&1; then
  if [ "$KILL" -eq 1 ]; then
    vlog "[KILL] Chiudo $PROC"
    if [ -n "$BUNDLE_ID" ]; then
      /usr/bin/osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' -e 'end run' "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    i=0
    while [ $i -lt 5 ] && /usr/bin/pgrep -x "$PROC" >/dev/null 2>&1; do sleep 1; i=$((i+1)); done
    /usr/bin/pkill -x "$PROC" >/dev/null 2>&1 || true
  else
    log "Attenzione: '$PROC' è in esecuzione. Chiudila o usa --kill."
  fi
fi

# --- Candidati: "TAG<TAB>PATH" ---
#   APP  = il bundle stesso
#   BID  = residuo che corrisponde al bundle ID (affidabile)
#   COPY = altra copia dell'app trovata da Spotlight   -> chiede sempre conferma
#   NAME = residuo che corrisponde solo al nome          -> chiede sempre conferma
add_path(){ { [ -e "$2" ] || [ -L "$2" ]; } || return 0; printf '%s\t%s\n' "$1" "$2" >> "$CAND"; }

# -mindepth 1: mai restituire la cartella base stessa (es. "Application Support")
find_in(){  # $1 tag, $2 base, $3... pattern
  tag="$1"; base="$2"; shift 2
  [ -d "$base" ] || return 0
  for pat in "$@"; do
    /usr/bin/find "$base" -mindepth 1 -maxdepth 1 -name "$pat" -exec printf '%s\t%s\n' "$tag" {} \; 2>/dev/null >> "$CAND"
  done
}

# 1) .app
[ -n "$APP_PATH" ] && [ "$IN_TRASH" -eq 0 ] && add_path APP "$APP_PATH"

if [ -n "$BUNDLE_ID" ]; then
  B="$BUNDLE_ID"

  # 2) Altre copie dell'app con lo stesso bundle ID, solo nelle cartelle note
  /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$B'" 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$APP_PATH" ] && continue
    case "$p" in "$HOME"/.Trash/*) continue ;; esac
    [ -n "$APP_PATH" ] && case "$p" in "$APP_PATH"/*) continue ;; esac
    case "$p" in *.app/*) vlog "[SKIP] dentro un altro bundle: $p"; continue ;; esac
    case "$p" in
      /Applications/*|"$HOME"/Applications/*) printf 'COPY\t%s\n' "$p" ;;
      *) vlog "[SKIP] fuori dalle cartelle note: $p" ;;
    esac
  done >> "$CAND"

  # 3) Residui per bundle ID (match esatto o "ID.qualcosa", non "ID*")
  find_in BID "$USER_LIB/Preferences"             "$B.plist"
  find_in BID "$USER_LIB/Preferences/ByHost"      "$B.*.plist"
  find_in BID "$USER_LIB/Application Support"     "$B" "$B.*"
  find_in BID "$USER_LIB/Caches"                  "$B" "$B.*"
  find_in BID "$USER_LIB/HTTPStorages"            "$B" "$B.binarycookies"
  find_in BID "$USER_LIB/Containers"              "$B" "$B.*"
  find_in BID "$USER_LIB/Group Containers"        "$B" "*.$B"
  find_in BID "$USER_LIB/Saved Application State" "$B.savedState"
  find_in BID "$USER_LIB/Application Scripts"     "$B" "$B.*"
  find_in BID "$USER_LIB/Logs"                    "$B" "$B.*"
  find_in BID "$USER_LIB/WebKit"                  "$B"
  find_in BID "$USER_LIB/Cookies"                 "$B.binarycookies"
  find_in BID "$USER_LIB/LaunchAgents"            "$B.plist" "$B.*.plist"

  find_in BID "$SYS_LIB/Preferences"              "$B.plist"
  find_in BID "$SYS_LIB/Application Support"      "$B" "$B.*"
  find_in BID "$SYS_LIB/Caches"                   "$B" "$B.*"
  find_in BID "$SYS_LIB/LaunchAgents"             "$B.plist" "$B.*.plist"
  find_in BID "$SYS_LIB/LaunchDaemons"            "$B.plist" "$B.*.plist"
  find_in BID "$SYS_LIB/PrivilegedHelperTools"    "$B" "$B.*"
fi

# 4) Fallback per nome (solo nomi abbastanza specifici, sempre con conferma)
NAME_LEN=${#APP_NAME}
if [ -n "$APP_NAME" ] && [ "$NAME_LEN" -ge "$MIN_NAME_LEN" ]; then
  N1="$APP_NAME"
  N2="$(printf '%s' "$APP_NAME" | /usr/bin/tr ' ' '_')"
  N3="$(printf '%s' "$APP_NAME" | /usr/bin/tr -d ' ')"
  for n in "$N1" "$N2" "$N3"; do
    find_in NAME "$USER_LIB/Preferences"         "*$n*.plist"
    find_in NAME "$USER_LIB/Application Support" "*$n*"
    find_in NAME "$USER_LIB/Caches"              "*$n*"
    find_in NAME "$USER_LIB/Logs"                "*$n*"
    find_in NAME "$SYS_LIB/Application Support"  "*$n*"
    find_in NAME "$SYS_LIB/Caches"               "*$n*"
  done
elif [ -n "$APP_NAME" ]; then
  log "Nome '$APP_NAME' troppo corto: salto la ricerca per nome."
fi

# Dedup per percorso, mantenendo il primo tag (APP > COPY > BID > NAME)
/usr/bin/awk -F "$TAB" 'NF>=2 && $2!="" && !seen[$2]++' "$CAND" > "$UNIQ"

# --- Header ---
printf "=== TARGET ===\n"
[ -n "$APP_ARG" ]   && printf "Arg        : %s\n" "$APP_ARG"
[ -n "$APP_PATH" ]  && printf "App path   : %s\n" "$APP_PATH"
[ -n "$APP_NAME" ]  && printf "App name   : %s\n" "$APP_NAME"
[ -n "$BUNDLE_ID" ] && printf "Bundle ID  : %s\n" "$BUNDLE_ID"
MODE="DRY-RUN"; [ "$DELETE" -eq 1 ] && MODE="DELETE"
printf "Mode       : %s (force=%s, kill=%s, forget_pkg=%s)\n\n" "$MODE" "$FORCE" "$KILL" "$FORGET"

# --- Protezioni sui percorsi ---
is_protected(){
  case "$1" in
    ""|/|/System|/System/*|/usr|/usr/*|/bin/*|/sbin/*|/private/var/db/*) return 0 ;;
    /Applications|/Applications/|/Library|/Library/|"$HOME"|"$HOME"/|"$HOME/Library"|"$HOME/Library/") return 0 ;;
    */../*|*/..|*/./*) return 0 ;;
    /*) ;;
    *) return 0 ;;   # percorso relativo: no
  esac
  # Mai una cartella "contenitore" di primo livello della Library
  parent="$(dirname "$1")"
  [ "$parent" = "$HOME" ] && return 0
  [ "$1" = "$USER_LIB/$(basename "$1")" ] && return 0
  [ "$1" = "$SYS_LIB/$(basename "$1")" ] && return 0
  return 1
}

# --- Rimozione di un elemento ---
TRASHED=0; REMOVED=0; FAILED=0; SKIPPED=0
FAIL_LIST=""

to_trash(){
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set f to POSIX file (item 1 of argv)' \
    -e 'tell application "Finder" to delete f' \
    -e 'end run' "$1" >/dev/null 2>&1
}

remove_item(){  # $1 path -> 0 rimosso, 1 errore; imposta HOW
  p="$1"; HOW="rm"

  # LaunchAgent/Daemon: scaricali prima di cancellare il plist
  case "$p" in
    "$USER_LIB/LaunchAgents/"*|"$SYS_LIB/LaunchAgents/"*)
      /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$p" >/dev/null 2>&1 || true ;;
    "$SYS_LIB/LaunchDaemons/"*)
      /usr/bin/sudo /bin/launchctl bootout system "$p" >/dev/null 2>&1 || true ;;
  esac

  # Preferenze utente: passa da cfprefsd, altrimenti la cache può riscriverle
  if [ -n "$BUNDLE_ID" ] && [ "$p" = "$USER_LIB/Preferences/$BUNDLE_ID.plist" ]; then
    /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  case "$p" in
    *.app|/Applications/*|"$HOME"/Applications/*)
      if to_trash "$p"; then HOW="trash"; return 0; fi
      /bin/rm -rf "$p" 2>/dev/null && [ ! -e "$p" ] && return 0
      /usr/bin/sudo /bin/rm -rf "$p" && [ ! -e "$p" ] && return 0
      return 1 ;;
    "$SYS_LIB"/*)
      /usr/bin/sudo /bin/rm -rf "$p" && [ ! -e "$p" ] && return 0
      return 1 ;;
    *)
      /bin/rm -rf "$p" 2>/dev/null
      { [ -e "$p" ] || [ -L "$p" ]; } || return 0
      # Container protetti da macOS (TCC): il Terminale non può, il Finder di solito sì
      case "$p" in
        "$USER_LIB/Containers/"*|"$USER_LIB/Group Containers/"*)
          if to_trash "$p" && [ ! -e "$p" ]; then HOW="trash"; return 0; fi ;;
      esac
      # rm fallito: riprova mostrando l'errore
      /bin/rm -rf "$p"
      { [ -e "$p" ] || [ -L "$p" ]; } || return 0
      return 1 ;;
  esac
}

if [ ! -s "$UNIQ" ]; then
  printf "Nessun file candidato trovato.\n"
else
  if [ "$DELETE" -eq 1 ] && [ "$FORCE" -ne 1 ] && [ "$HAS_TTY" -ne 1 ]; then
    die "nessun terminale per chiedere conferma: usa --force (o lancialo da Terminale)"
  fi

  exec 3< "$UNIQ"
  while IFS="$TAB" read -r tag path <&3; do
    [ -n "$path" ] || continue

    if is_protected "$path"; then
      printf "[SKIP] %s (percorso protetto)\n" "$path"
      SKIPPED=$((SKIPPED+1)); continue
    fi

    kind="FILE"; [ -d "$path" ] && kind="DIR "
    note=""
    case "$tag" in
      NAME) note="  (match per nome: conferma sempre)" ;;
      COPY) note="  (altra copia dell'app: conferma sempre)" ;;
    esac
    printf "[%-4s] %s %s%s\n" "$tag" "$kind" "$path" "$note"

    [ "$DELETE" -eq 1 ] || continue

    need_confirm=1
    if [ "$FORCE" -eq 1 ]; then
      case "$tag" in APP|BID) need_confirm=0 ;; esac
    fi

    if [ "$need_confirm" -eq 1 ]; then
      if [ "$HAS_TTY" -ne 1 ]; then
        printf "  -> saltato (serve conferma, nessun terminale)\n"
        SKIPPED=$((SKIPPED+1)); continue
      fi
      if ! ask "Cancello questo elemento?"; then
        SKIPPED=$((SKIPPED+1)); continue
      fi
    fi

    if remove_item "$path"; then
      if [ "$HOW" = "trash" ]; then
        printf "  -> spostato nel Cestino\n"; TRASHED=$((TRASHED+1))
      else
        printf "  -> rimosso\n"; REMOVED=$((REMOVED+1))
      fi
    else
      printf "  -> ERRORE: non rimosso\n"
      FAILED=$((FAILED+1))
      FAIL_LIST="${FAIL_LIST}  $path
"
    fi
  done
  exec 3<&-

  if [ "$DELETE" -eq 1 ]; then
    printf "\n=== RIEPILOGO ===\n"
    printf "Nel Cestino : %d\n" "$TRASHED"
    printf "Rimossi     : %d\n" "$REMOVED"
    printf "Saltati     : %d\n" "$SKIPPED"
    printf "Errori      : %d\n" "$FAILED"
    [ "$TRASHED" -gt 0 ] && printf "(gli elementi nel Cestino spariscono quando lo svuoti)\n"
    if [ "$FAILED" -gt 0 ]; then
      printf "\nNon rimossi:\n%s" "$FAIL_LIST"
      case "$FAIL_LIST" in
        *"/Library/Containers/"*|*"/Library/Group Containers/"*)
          printf "Suggerimento: macOS protegge i Container delle app e anche il Finder non è riuscito.\n"
          printf "Dai al Terminale 'Accesso completo al disco' (Impostazioni > Privacy e sicurezza),\n"
          printf "chiudi e riapri il Terminale, poi riprova. Oppure trascina le cartelle nel Cestino dal Finder.\n" ;;
      esac
    fi
  else
    printf "\nℹ Dry-run completato. Aggiungi --delete per cancellare.\n"
  fi
fi

# --- pkg receipts ---
: > "$PKG_TMP"
set --
[ -n "$BUNDLE_ID" ] && set -- "$@" -e "$BUNDLE_ID"
if [ -n "$APP_NAME" ] && [ "$NAME_LEN" -ge "$MIN_NAME_LEN" ]; then
  set -- "$@" -e "$(printf '%s' "$APP_NAME" | /usr/bin/tr ' ' '_')" -e "$(printf '%s' "$APP_NAME" | /usr/bin/tr -d ' ')"
fi
if [ $# -gt 0 ]; then
  printf "\n=== pkg receipts correlati (se presenti) ===\n"
  /usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -iF "$@" > "$PKG_TMP" || true
  if [ ! -s "$PKG_TMP" ]; then
    printf "(nessuno trovato)\n"
  else
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      vol="$(/usr/sbin/pkgutil --pkg-info "$pkg" 2>/dev/null | /usr/bin/awk -F': ' '/^volume:/{print $2}')"
      loc="$(/usr/sbin/pkgutil --pkg-info "$pkg" 2>/dev/null | /usr/bin/awk -F': ' '/^location:/{print $2}')"
      nfiles="$(/usr/sbin/pkgutil --files "$pkg" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
      printf "%s  (file: %s, in: %s%s)\n" "$pkg" "$nfiles" "${vol:-/}" "$loc"
    done < "$PKG_TMP"
    printf "\nNota: --forget-pkg cancella solo la RICEVUTA, non i file installati.\n"
    printf "Per vedere cosa ha installato un pacchetto: pkgutil --files <pkg>\n"
    if [ "$FORGET" -eq 1 ]; then
      if [ "$DELETE" -eq 1 ]; then
        printf "\nEseguo pkgutil --forget...\n"
        while IFS= read -r pkg; do
          [ -n "$pkg" ] || continue
          /usr/bin/sudo /usr/sbin/pkgutil --forget "$pkg" || log "pkgutil --forget fallito: $pkg"
        done < "$PKG_TMP"
      else
        printf "(dry-run: --forget-pkg richiede anche --delete)\n"
      fi
    else
      printf "Aggiungi --forget-pkg --delete per eseguire pkgutil --forget.\n"
    fi
  fi
fi

[ "$FAILED" -eq 0 ] || exit 2
exit 0
