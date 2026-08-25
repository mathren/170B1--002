#!/usr/bin/env bash
#
# build-and-deploy.sh
#
# Build the site locally with Emacs, then optionally commit + push it to
# the git repo, and rsync the built HTML to the remote server.
#
# Usage: build-and-deploy.sh [--all] [-y] [COMMIT MESSAGE...]
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly REMOTE_HOST="lavinia"
# shellcheck disable=SC2088  # tilde expands remotely (rsync/ssh), not here
readonly REMOTE_PATH="~/public_html/courses/170B1--02/"
readonly SITE_URL="https://www.as.arizona.edu/~mrenzo/courses/170B1--02/index.html"
readonly DEFAULT_COMMIT_MSG="Update website"

# Globals populated by parse_args.
build_all=false
assume_yes=false
commit_msg_words=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--all] [-y] [COMMIT MESSAGE...]

Build the site locally with Emacs and (optionally) commit, push, and
rsync it to the remote server.

Options:
  --all         Build every file (passed to build-site.el as 'all')
  -y, --yes     Assume "yes" for every prompt (non-interactive)
  -h, --help    Show this help and exit

Any other arguments are joined together and used as the git commit
message. If none are given, "${DEFAULT_COMMIT_MSG}" is used.
EOF
}

# parse_args ARGS
# Single-pass parser:
# recognizes --all / -y / --yes / -h /--help
# anywhere in the argument list; everything else is
# collected (in order) as commit message words.
# "--" stops flag parsing, in case a message word needs to look like "-y" or "--all"
# itself.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                build_all=true
                ;;
            -y|--yes)
                assume_yes=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                commit_msg_words+=("$@")
                break
                ;;
            *)
                commit_msg_words+=("$1")
                ;;
        esac
        shift
    done
}

# confirm PROMPT
# Prints PROMPT and waits for a y/Y answer, unless -y was given.
confirm() {
    local prompt="$1"
    local reply

    if [[ "${assume_yes}" == true ]]; then
        return 0
    fi

    read -r -p "${prompt} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# build_site
# Runs emacs in batch mode (-Q: no init file) to build the site.
build_site() {
    if [[ "${build_all}" == true ]]; then
        emacs -Q --script build-site.el -- all
    else
        emacs -Q --script build-site.el
    fi
}

main() {
    parse_args "$@"

    echo "Building site locally with Emacs..."
    if ! build_site; then
        echo "Building failed. See error above" >&2
        exit 1
    fi
    echo "Successfully built site locally with emacs!"
    echo
    git status
    echo

    local pushed=false
    if confirm "Push everything to repo?"; then
        git remote -v

        local commit_message
        if [[ ${#commit_msg_words[@]} -eq 0 ]]; then
            commit_message="${DEFAULT_COMMIT_MSG}"
        else
            commit_message="${commit_msg_words[*]}"
        fi

        git add .
        # A "nothing to commit" failure here shouldn't abort the script.
        git commit -am "${commit_message}" || echo "Nothing to commit."
        git push
        pushed=true
    fi

    local pulled=false
    if [[ "${pushed}" == true ]]; then
        if confirm "Rsync to remote server?"; then
            if rsync -arz --exclude="*~" html-content/* "${REMOTE_HOST}:${REMOTE_PATH}"; then
                pulled=true
            fi
        fi
    else
        if confirm "Open website home locally?"; then
            xdg-open ./html-content/index.html || true
        else
            echo "Ok, not opening!"
        fi
    fi

    echo
    echo "Summary:"
    echo
    if [[ "${pushed}" == false ]]; then
        echo "Done: local build, not pushed, check html file"
    elif [[ "${pulled}" == true ]]; then
        echo "Done: local build pushed, and synced with remote! Website is online at ${SITE_URL}"
    else
        echo "Done: local build pushed, but not synced with remote! Latest version of website is *NOT* online"
    fi
}

main "$@"
