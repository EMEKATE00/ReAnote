#!/usr/bin/env bash
# Opens a terminal positioned in the ReAnote folder, ready to run ./reanotar.sh
# Used by Open_ReAnote.desktop (double-click launcher). Can also be run directly.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

WELCOME='echo; echo "ReAnote is ready. Try:  ./reanotar.sh --help"; echo'

# Try common terminal emulators in order until one is found.
for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal tilix xterm; do
    if command -v "$term" >/dev/null 2>&1; then
        case "$term" in
            gnome-terminal|tilix|mate-terminal)
                exec "$term" --working-directory="$DIR" -- bash -c "$WELCOME; exec bash"
                ;;
            konsole)
                exec "$term" --workdir "$DIR" -e bash -c "$WELCOME; exec bash"
                ;;
            xfce4-terminal)
                exec "$term" --working-directory="$DIR" -e "bash -c '$WELCOME; exec bash'"
                ;;
            *)
                exec "$term" -e bash -c "cd \"$DIR\"; $WELCOME; exec bash"
                ;;
        esac
    fi
done

echo "No supported terminal emulator was found on this system." >&2
echo "Open a terminal manually and run: cd \"$DIR\" && ./reanotar.sh --help" >&2
exit 1
