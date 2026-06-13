#!/usr/bin/env bash

# Folder Ownership and Access Fixer
# Lets the user select a folder, then makes the original execution user the owner
# and grants that user full access recursively.
#
# Uses zenity when a graphical display is available.
# Falls back to dialog for terminal or SSH sessions.

set -euo pipefail

if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    EXECUTION_USER="${SUDO_USER}"
    EXECUTION_GROUP="$(id -gn "${SUDO_USER}")"
else
    EXECUTION_USER="$(id -un)"
    EXECUTION_GROUP="$(id -gn)"
fi

USE_ZENITY=false
USE_DIALOG=false

if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    USE_ZENITY=true
else
    USE_DIALOG=true
fi

if [[ "${USE_ZENITY}" == true ]]; then
    if ! command -v zenity >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y zenity
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

else
    if ! command -v dialog >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y dialog
    fi

    SELECTED_FOLDER="$(dialog \
        --stdout \
        --title "Select a folder to take ownership of" \
        --dselect "${HOME}/" \
        20 80)" || {
            clear
            echo "No folder selected."
            exit 0
        }

    clear

    if [[ -z "${SELECTED_FOLDER}" ]]; then
        echo "No folder selected."
        exit 0
    fi

    if [[ ! -d "${SELECTED_FOLDER}" ]]; then
        echo "The selected path is not a folder:"
        echo "${SELECTED_FOLDER}"
        exit 1
    fi

    echo "This will recursively change ownership and permissions for:"
    echo
    echo "${SELECTED_FOLDER}"
    echo
    echo "Owner will become:"
    echo "${EXECUTION_USER}:${EXECUTION_GROUP}"
    echo
    read -r -p "Continue? [y/N] " CONFIRMATION

    case "${CONFIRMATION}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Cancelled."
            exit 0
            ;;
    esac
fi

# Change owner to the execution user.
sudo chown -R "${EXECUTION_USER}:${EXECUTION_GROUP}" "${SELECTED_FOLDER}"

# Give the user full access.
# u+rwX gives:
# - read/write to files and folders
# - execute only to folders and already-executable files
chmod -R u+rwX "${SELECTED_FOLDER}"

if [[ "${USE_ZENITY}" == true ]]; then
    zenity --info \
        --title="Complete" \
        --text="Ownership and user access updated successfully."

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${SELECTED_FOLDER}" >/dev/null 2>&1 &
    fi
else
    echo
    echo "Complete."
    echo "Ownership and user access updated successfully for:"
    echo "${SELECTED_FOLDER}"
fi
