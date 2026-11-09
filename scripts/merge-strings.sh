#!/bin/sh
# Writes Localizable.strings into the built app: AutoCore's strings first,
# then the app's own, so one app can translate both. Run it as a build phase
# after the resources are copied:
#   "<AutoCore>/scripts/merge-strings.sh" "<AutoCore>/Resources" "<app folder with xx.lproj>"
set -eu
CORE="$1"
APP="$2"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
langs=""
for dir in "$CORE"/*.lproj "$APP"/*.lproj; do
    [ -d "$dir" ] || continue
    lang=$(basename "$dir")
    case " $langs " in *" $lang "*) ;; *) langs="$langs $lang" ;; esac
done
for lang in $langs; do
    out="$DEST/$lang/Localizable.strings"
    mkdir -p "$DEST/$lang"
    : > "$out.tmp"
    for file in "$CORE/$lang/Localizable.strings" "$APP/$lang/Localizable.strings"; do
        if [ -f "$file" ]; then
            cat "$file" >> "$out.tmp"
            printf '\n' >> "$out.tmp"
        fi
    done
    plutil -lint -s "$out.tmp"
    mv "$out.tmp" "$out"
done
