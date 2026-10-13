#!/usr/bin/env bash

set -uo pipefail

GITHUB_USER="${1:-}"
REPO_LIMIT=1000

if [ -z "$GITHUB_USER" ]; then
    echo "You must provide your github username to continue"
fi

# Check required commands
for cmd in gh git ssh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is not installed."
        exit 1
    fi
done

# Check GitHub CLI authentication
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo "Please authenticate with GitHub CLI:"
    echo "  gh auth login --hostname github.com"
    exit 1
fi

ACTIVE_USER=$(gh api user --jq '.login') || exit 1

if [[ "$ACTIVE_USER" != "$GITHUB_USER" ]]; then
    echo "ERROR: GitHub CLI is using '$ACTIVE_USER', not '$GITHUB_USER'."
    echo "Switch accounts with:"
    echo "  gh auth switch --hostname github.com --user $GITHUB_USER"
    exit 1
fi

# Use the default SSH configuration and key.
echo "Checking your default GitHub SSH authentication..."

ssh_output=$(ssh -T git@github.com 2>&1) || true
echo "$ssh_output"

if [[ "$ssh_output" != *"successfully authenticated"* ]]; then
    echo "ERROR: SSH authentication failed."
    echo "Check your default SSH key and GitHub SSH settings."
    exit 1
fi

if [[ "$ssh_output" != *"$GITHUB_USER"* ]]; then
    echo "ERROR: Your default SSH key is not authenticating as '$GITHUB_USER'."
    echo "Your GitHub CLI account is correct, but your SSH account differs."
    echo "Register the correct public key with '$GITHUB_USER' or configure SSH."
    exit 1
fi

echo "Authenticated as $GITHUB_USER."
echo
echo "Fetching repositories..."

if ! repos=$(gh repo list "$GITHUB_USER" \
    --limit "$REPO_LIMIT" \
    --json nameWithOwner,description,isPrivate \
    --jq 'sort_by(.nameWithOwner)[] |
    [.nameWithOwner, (.isPrivate | tostring), (.description // "")] |
    @tsv'); then
    echo "ERROR: Could not fetch repositories."
    exit 1
fi

if [[ -z "$repos" ]]; then
    echo "No repositories found."
    exit 0
fi

repo_names=()

echo
echo "========== Available Repositories =========="

while IFS=$'\t' read -r name private description; do
    [[ -z "$name" ]] && continue
    repo_names+=("$name")

    visibility="Public"
    [[ "$private" == "true" ]] && visibility="Private"

    printf "%3d. %s [%s]\n" "${#repo_names[@]}" "$name" "$visibility"

    [[ -n "$description" ]] && printf "     %s\n" "$description"
done <<< "$repos"

TOTAL=${#repo_names[@]}

if (( TOTAL == 0 )); then
    echo "No repositories found."
    exit 0
fi

echo
echo "Enter numbers (1,3,5), a range (1-5), all, or q to quit."
read -r -p "Your selection: " selection

case "$selection" in
    q|Q)
        echo "Cancelled."
        exit 0
        ;;
esac

selected_indices=()
declare -A seen=()

if [[ "$selection" == "all" || "$selection" == "ALL" ]]; then
    for ((i = 1; i <= TOTAL; i++)); do
        selected_indices+=("$i")
    done
else
    IFS=',' read -ra parts <<< "$selection"

    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"

        if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
            start="${part%-*}"
            end="${part#*-}"

            if (( start < 1 || end > TOTAL || start > end )); then
                echo "ERROR: Invalid range '$part'."
                exit 1
            fi

            for ((i = start; i <= end; i++)); do
                if [[ -z "${seen[$i]+x}" ]]; then
                    selected_indices+=("$i")
                    seen[$i]=1
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]] &&
             (( part >= 1 && part <= TOTAL )); then
            if [[ -z "${seen[$part]+x}" ]]; then
                selected_indices+=("$part")
                seen[$part]=1
            fi
        else
            echo "ERROR: Invalid selection '$part'."
            exit 1
        fi
    done
fi

if (( ${#selected_indices[@]} == 0 )); then
    echo "No repositories selected."
    exit 0
fi

# Ask for destination directory
echo
read -r -p "Destination directory [$PWD]: " destination
destination="${destination:-$PWD}"

if [[ "$destination" == "~" ]]; then
    destination="$HOME"
elif [[ "$destination" == "~/"* ]]; then
    destination="$HOME/${destination#~/}"
fi

if [[ "$destination" != /* ]]; then
    destination="$PWD/$destination"
fi

if ! mkdir -p -- "$destination"; then
    echo "ERROR: Cannot create destination directory."
    exit 1
fi

destination=$(cd "$destination" && pwd -P) || exit 1

echo
echo "Account: $GITHUB_USER"
echo "Selected repositories: ${#selected_indices[@]}"
echo "Destination: $destination"

for i in "${selected_indices[@]}"; do
    echo "  - ${repo_names[$((i - 1))]}"
done

echo
read -r -p "Start cloning? (y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

# Clone sequentially using the default SSH configuration
success=0
skipped=0
failed=0
current=0
total_selected=${#selected_indices[@]}

for i in "${selected_indices[@]}"; do
    current=$((current + 1))
    repo="${repo_names[$((i - 1))]}"
    folder="${repo##*/}"
    target="$destination/$folder"

    echo
    echo "[$current/$total_selected] $repo"

    if [[ -e "$target" ]]; then
        echo "SKIPPED: $target already exists."
        skipped=$((skipped + 1))
        continue
    fi

    if git clone "git@github.com:${repo}.git" "$target"; then
        echo "SUCCESS: $repo"
        success=$((success + 1))
    else
        echo "FAILED: $repo"
        failed=$((failed + 1))
    fi
done

echo
echo "=============== SUMMARY ==============="
echo "Successful: $success"
echo "Skipped:    $skipped"
echo "Failed:     $failed"
echo "Destination: $destination"
echo "========================================"
