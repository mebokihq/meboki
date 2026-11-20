Meboki bench kit: measures Apple Intelligence (and optionally Gemma) on this Mac. Needs macOS 26.
1. Unzip, open Terminal, cd into this folder.
2. ./run-apple.sh        (no arguments; 20-40 min; turn Apple Intelligence on first)
3. Optional: ./run-gemma.sh [/path/to/Meboki.app]   (uses the app's llama-server and its downloaded Gemma)
4. Send back meboki-bench-results.zip (made automatically from results/).
If macOS blocks meboki-eval-run after AirDrop or a download, run in this folder:
   xattr -dr com.apple.quarantine .
