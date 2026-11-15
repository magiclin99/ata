# Sourced by build-app.sh and release.sh. One guarded window around every codesign call that uses the dedicated
# signing keychain, so macOS never has a reason to show a "enter the keychain password" dialog:
#
#   signing_keychain_open    unlock (password via stdin, never argv) → check it really is unlocked → put it on the
#                            user search list (codesign only finds identities there)
#   ... codesign --keychain "$KC" ...
#   signing_keychain_close   restore the exact previous search list → lock → check it really is locked
#
# Opening installs an EXIT trap that closes again, so a failed codesign still leaves the keychain locked and off the
# search list. Nothing here (or in the callers) touches the keychain while it is locked: no find-identity, no
# show-keychain-info (that one prompts on a locked keychain).
#
# Needs: KC (keychain path) and KC_PASSWORD_FILE (file holding its password).

_kc_state() { swift "$(dirname "${BASH_SOURCE[0]}")/keychain-state.swift" "$KC" 2>/dev/null; }

signing_keychain_open() {
    [ -f "$KC" ] || { echo "signing keychain not found: $KC" >&2; exit 1; }
    [ -f "${KC_PASSWORD_FILE:-}" ] || { echo "signing keychain password file not found: ${KC_PASSWORD_FILE:-<unset>}" >&2; exit 1; }
    _KC_SEARCH_BEFORE=()
    while IFS= read -r l; do l="${l#"${l%%[![:space:]]*}"}"; l="${l%\"}"; _KC_SEARCH_BEFORE+=("${l#\"}"); done \
        < <(security list-keychains -d user)
    _KC_OPEN=1
    trap signing_keychain_close EXIT
    printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$KC_PASSWORD_FILE")" "$KC" | security -i >/dev/null 2>&1
    # `security -i` reports a wrong password silently; codesign would then fall back to a GUI prompt. Check first.
    if [ "$(_kc_state)" != unlocked ]; then
        echo "could not unlock the signing keychain $KC (wrong password in $KC_PASSWORD_FILE?)" >&2; exit 1
    fi
    security list-keychains -d user -s "${_KC_SEARCH_BEFORE[@]}" "$KC"
}

signing_keychain_close() {
    [ "${_KC_OPEN:-0}" = 1 ] || return 0
    _KC_OPEN=0
    trap - EXIT
    security list-keychains -d user -s "${_KC_SEARCH_BEFORE[@]}"
    security lock-keychain "$KC"
    if [ "$(_kc_state)" != locked ]; then echo "signing keychain is still unlocked: $KC" >&2; exit 1; fi
}
