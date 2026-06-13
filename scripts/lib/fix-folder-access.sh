#!/usr/bin/env bash

# Folder Ownership and Access Fixer
# Lets the user select a folder, then makes the current user the owner
# and grants full user access recursively.

set -euo pipefail

EXECUTION_USER="$(id -un)"
EXECUTION_GROUP="$(id -gn)"

if ! command -v zenity >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y zenity
fi

SELECTED_FOLDER="$(zenity \
    --file-selection \
    --directory \
    --title="Select a folder to take ownership of")"

if [[ -z "${SELECTED_FOLDER}" ]]; then
    echo "No folder selected."
    exit 0
fi

if [[ ! -d "${SELECTED_FOLDER}" ]]; then
    zenity --error --text="The selected path is not a folder."
    exit 1
fi

zenity --question \
    --title="Confirm ownership change" \
    --text="This will recursively change ownership and permissions for:

${SELECTED_FOLDER}

Owner will become:
${EXECUTION_USER}:${EXECUTION_GROUP}

Continue?"

# Change owner to the user running the script.
sudo chown -R "${EXECUTION_USER}:${EXECUTION_GROUP}" "${SELECTED_FOLDER}"

# Give the user full access.
# u+rwX gives:
# - read/write to files and folders
# - execute only to folders and already-executable files
chmod -R u+rwX "${SELECTED_FOLDER}"

zenity --info \
    --title="Complete" \
    --text="Ownership and user access updated successfully."

# Open the folder in the default file manager.
xdg-open "${SELECTED_FOLDER}" >/dev/null 2>&1 &
