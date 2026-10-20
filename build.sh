#!/usr/bin/env bash
#
# build-and-deploy.sh
#
# Build the site locally with Emacs, then optionally commit + push it to
# the git repo, and rsync the built HTML to the remote server.
#
# Without --all, only the files under html-content/ that changed with
# respect to HEAD (according to git) are rsynced.
#
# Usage: build-and-deploy.sh [--all] [-y] [COMMIT MESSAGE...]
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly HTML_DIR="html-content"
readonly REMOTE_HOST="lavinia"
# shellcheck disable=SC2088  # tilde expands remotely (rsync/ssh), not here
readonly REMOTE_PATH="~/public_html/courses/170B1--02/"
readonly SITE_URL="https://www.as.arizona.edu/~mrenzo/courses/170B1--02/index.html"
readonly DEFAULT_COMMIT_MSG="Update website"

# Globals populated by parse_args.
build_all=false
assume_yes=false
commit_msg_words=()

# Populated by collect_changed_files (paths relative to HTML_DIR).
changed_files=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--all] [-y] [COMMIT MESSAGE...]

Build the site locally with Emacs and (optionally) commit, push, and
rsync it to the remote server.

By default only the files in ${HTML_DIR}/ that git reports as changed
(modified or untracked) are rsynced. Push and rsync default to "yes".

Options:
  --all         Build every file (passed to build-site.el as 'all')
                and rsync all of ${HTML_DIR}/
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

# confirm PROMPT [DEFAULT]
# Prints PROMPT and waits for an answer, unless -y was given.
# DEFAULT is "y" or "n" (default "n") and is used on empty input.
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local reply

    if [[ "${assume_yes}" == true ]]; then
        return 0
    fi

    if [[ "${default}" == y ]]; then
        read -r -p "${prompt} [Y/n] " reply
        [[ ! "${reply}" =~ ^[Nn] ]]
    else
        read -r -p "${prompt} [y/N] " reply
        [[ "${reply}" =~ ^[Yy]$ ]]
    fi
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

# collect_changed_files
# Must run BEFORE committing. Fills changed_files with files under
# HTML_DIR that differ from HEAD (deletions excluded) or are untracked,
# relative to HTML_DIR, skipping backup files (*~).
collect_changed_files() {
    mapfile -t changed_files < <(
        {
            git diff --name-only --diff-filter=d HEAD -- "${HTML_DIR}"
            git ls-files --others --exclude-standard -- "${HTML_DIR}"
        } | sed "s|^${HTML_DIR}/||" | grep -v '~$' | sort -u
    )
}

# sync_remote
# rsyncs everything with --all, otherwise only changed_files.
sync_remote() {
    if [[ "${build_all}" == true ]]; then
        rsync -arz --exclude="*~" "${HTML_DIR}"/* "${REMOTE_HOST}:${REMOTE_PATH}"
        return
    fi

    if [[ ${#changed_files[@]} -eq 0 ]]; then
        echo "No changed files in ${HTML_DIR}/, nothing to rsync."
        return 0
    fi

    echo "Files to rsync:"
    printf '  %s\n' "${changed_files[@]}"
    printf '%s\n' "${changed_files[@]}" |
        rsync -az --files-from=- "${HTML_DIR}/" "${REMOTE_HOST}:${REMOTE_PATH}"
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

    # Record changed files before the commit makes them match HEAD.
    collect_changed_files

    local pushed=false
    if confirm "Push everything to repo?" y; then
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
        if confirm "Rsync to remote server?" y; then
            if sync_remote; then
                pulled=true
            fi
        fi
    else
        if confirm "Open website home locally?" n; then
            xdg-open "./${HTML_DIR}/index.html" || true
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
