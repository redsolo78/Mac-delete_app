# macOS App Uninstaller 

 Uso:
   ./uninstall.sh "NomeApp"                # dry-run
   ./uninstall.sh "NomeApp.app" --delete   # rimuove davvero
   ./uninstall.sh --bundle-id com.vendor.App --delete
 
 Opzioni: --delete --force --kill --forget-pkg --bundle-id ID --verbose|-v --trace