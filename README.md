# macOS App Uninstaller

Script POSIX `/bin/sh` che rimuove un'app macOS e i suoi residui (preferenze, cache, container, LaunchAgent/Daemon, helper…).
Di default è in **dry-run**: mostra cosa cancellerebbe senza toccare nulla.

## Uso

> Lancialo **senza `sudo`**: chiede la password da solo quando serve (file in `/Library`).
> Con `sudo` `$HOME` diventa `/var/root` e i residui in `~/Library` non verrebbero trovati.

```sh
./uninstall.sh "NomeApp"                      # dry-run
./uninstall.sh "NomeApp.app" --delete         # rimuove, chiede conferma per ogni elemento
./uninstall.sh "NomeApp" --delete --force     # niente conferma per app + match per bundle ID
./uninstall.sh --bundle-id com.vendor.App --delete
```

| Opzione | Effetto |
|---|---|
| `--delete` | Rimuove davvero (senza: dry-run) |
| `--force` | Niente conferma per i match affidabili (`APP`, `BID`). I match `NAME` e `COPY` chiedono **sempre** conferma |
| `--kill` | Chiude l'app se è in esecuzione |
| `--forget-pkg` | Con `--delete`, esegue `pkgutil --forget` sulle ricevute trovate |
| `--bundle-id ID` | Usa questo bundle ID |
| `--keep-fda` | Non revoca a fine script l'Accesso completo al disco |
| `--verbose`, `-v` | Output dettagliato |
| `--trace` | `set -x` |
| `--help`, `-h` | Aiuto |

## Accesso completo al disco (temporaneo)

Per cancellare i Container delle app macOS richiede che il terminale abbia l'*Accesso completo al disco*.
Lo script lo gestisce come un permesso **temporaneo**:

1. **All'avvio con `--delete`** controlla se il terminale ha il permesso. Se manca mostra un popup
   (con pulsante *Apri Impostazioni*) e **si ferma** (exit 3) senza toccare nulla.
2. **A fine esecuzione** — anche in caso di errore o Ctrl+C — lo revoca con
   `tccutil reset SystemPolicyAllFiles <terminale>`. Il terminale sparisce dalla lista: la volta dopo va
   riaggiunto con **+**. Per tenerlo: `--keep-fda`.

Flusso consigliato:
```sh
./uninstall.sh "NomeApp"            # dry-run, non serve il permesso
# Impostazioni > Privacy e sicurezza > Accesso completo al disco > attiva Terminale, Cmd+Q e riapri
./uninstall.sh "NomeApp" --delete   # cancella e alla fine revoca il permesso
```
Attenzione: anche il dry-run revoca il permesso alla fine. Se lo dai prima del dry-run, usa `--keep-fda`
oppure passa subito a `--delete`.

Terminali riconosciuti: Terminale, iTerm2, Ghostty, Warp, Visual Studio Code. Con un altro terminale lo
script avvisa e il permesso va tolto a mano.

## Come classifica i candidati

| Tag | Cosa | Con `--force` |
|---|---|---|
| `APP` | Il bundle `.app` (va nel **Cestino** tramite Finder) | senza conferma |
| `BID` | Residuo che corrisponde al bundle ID (`ID`, `ID.*`) | senza conferma |
| `COPY` | Altra copia dell'app con lo stesso bundle ID | chiede conferma |
| `NAME` | Residuo che corrisponde solo al nome dell'app | chiede conferma |

Senza un terminale (es. lanciato da uno script) i `NAME`/`COPY` vengono saltati.

## Cartelle controllate

`~/Library`: Preferences (+ByHost), Application Support, Caches, HTTPStorages, Containers, Group Containers,
Saved Application State, Application Scripts, Logs, WebKit, Cookies, LaunchAgents.
`/Library`: Preferences, Application Support, Caches, LaunchAgents, LaunchDaemons, PrivilegedHelperTools.

## Note

- I LaunchAgent/Daemon vengono scaricati con `launchctl bootout` prima di cancellare il plist.
- Le preferenze utente passano da `defaults delete` per non farle riscrivere da `cfprefsd`.
- macOS (Sonoma+) protegge `~/Library/Containers`: se `rm` fallisce, lo script sposta il Container
  nel Cestino tramite Finder. Se fallisce anche così, dai al Terminale *Accesso completo al disco*
  (Impostazioni > Privacy e sicurezza), chiudi e riapri il Terminale e riprova.
- Se l'app è già nel Cestino lo script la usa per ricavare il bundle ID (serve *Accesso completo al
  disco* per leggere `~/.Trash`). Se l'app non c'è più, usa `--bundle-id`:
  `ls ~/Library/Containers | grep -i nomeapp`.
- `pkgutil --forget` cancella solo la **ricevuta** del pacchetto, non i file installati
  (vedi `pkgutil --files <pkg>`).
- Microsoft Office: lo script non tocca `~/Library/Group Containers/UBF8T346G9.Office`, condiviso tra
  Word/Excel/PowerPoint/Outlook. Cancellalo a mano solo se rimuovi tutto Office.
- Exit code: `0` ok, `1` errore di uso, `2` alcuni elementi non sono stati rimossi,
  `3` manca l'Accesso completo al disco.

## Changelog

### v2.2
- Con `--delete` richiede l'Accesso completo al disco: se manca, popup con link alle Impostazioni e stop.
- A fine script (anche su errore/Ctrl+C) revoca sempre il permesso con `tccutil`; `--keep-fda` per tenerlo.

### v2.1
- Si ferma se lanciato con `sudo` (con `$HOME=/var/root` non troverebbe i residui).
- Container protetti: se `rm` fallisce, li sposta nel Cestino tramite Finder.
- Cerca l'app anche nel Cestino (anche rinominata) per ricavare il bundle ID, senza ricestinarla.
- Se il bundle ID è sconosciuto, avvisa e suggerisce `--bundle-id`.

### v2
- Rimossa l'auto-invocazione accidentale in fondo allo script (ricorsione infinita con `--force --delete`).
- La conferma `[y/N]` legge da `/dev/tty`: prima leggeva il file dei candidati e saltava un elemento su due.
- `vlog` non fa più uscire lo script con `set -e` (es. `--kill` senza `--verbose`).
- `find -mindepth 1`: un nome come "Support" non può più far cancellare l'intera `Application Support`.
- Pattern per bundle ID più stretti (`ID` / `ID.*` invece di `ID*`).
- Match per nome e copie dell'app trovate da Spotlight chiedono sempre conferma; nomi sotto 4 caratteri esclusi.
- Ricerca app: se più app corrispondono, si ferma invece di sceglierne una a caso.
- Bundle ID letto da `Info.plist` (PlistBuddy), validato; niente AppleScript che può avviare l'app.
- `osascript` riceve nome/percorso come argomenti (niente injection con le virgolette).
- Un errore su un singolo elemento non interrompe più la rimozione; riepilogo finale.
- Aggiunti `~/Library/LaunchAgents`, `HTTPStorages`, `/Library/PrivilegedHelperTools`.
- `launchctl bootout` prima di cancellare agent/daemon; `defaults delete` per le preferenze.
- Ricerca pkg receipts anche per nome (`Microsoft_PowerPoint`), con numero di file installati.
- `mktemp` portabile.
