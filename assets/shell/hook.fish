#!/usr/bin/env fish
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Island shell integration for Fish: https://github.com/landlock-lsm/island
#
# # Usage
#   source (island hook fish | psub)
#
# You can use the $_ISLAND_PROFILES variable (list) in your prompt to display
# the active Island profiles.
#
# # Features
# - Transparent wrapping of external commands (including pipelines and fd-pipe
#   forms like `2>|`).
# - Path invocations are rewritten in-buffer so history shows `island run --`.
# - Immediate profile refresh when running `island`.
#
# # Limitations
# - Fish has no ${(z)BUFFER} equivalent.
# - `commandline -o` is deprecated and also does not report operators (just like
#   `commandline --tokens-expanded`), so it cannot be used to detect command
#   boundaries.
# - Parsing is best-effort and quote-aware only; complex constructs such as
#   command substitutions are not handled.
#
# # Example usage in fish_prompt:
#
# functions --copy fish_prompt _orig_fish_prompt
# function fish_prompt
#     if test -n "$_ISLAND_PROFILES"
#         echo -sn (set_color blue) "island: " "$_ISLAND_PROFILES" " "
#     end
#     _orig_fish_prompt
# end


# Ensure clean state if re-sourced.
if functions -q _island_unhook
    _island_unhook
end

function _island_chpwd --on-variable PWD
    set -l profiles (command island status 2>/dev/null)
    if test $status -eq 0
        set -g _ISLAND_PROFILES $profiles
    else
        set -e _ISLAND_PROFILES
    end
end

function _island_wrap_cmd --argument-names cmd
    if test -z "$cmd"
        return
    end
    if test "$cmd" = "island"
        return
    end

    set -l cmd_type (type -t -- $cmd 2>/dev/null)
    if test "$cmd_type" = "function" -o "$cmd_type" = "builtin"
        return
    end
    if test "$cmd_type" = ""
        return
    end

    if set -q _ISLAND_WRAPPED_CMDS[1]
        if contains -- $cmd $_ISLAND_WRAPPED_CMDS
            return
        end
    end

    function $cmd --wraps $cmd
        command island run -- $cmd $argv
    end
    set -g _ISLAND_WRAPPED_CMDS $cmd $_ISLAND_WRAPPED_CMDS
end

function _island_accept_line
    commandline --is-valid
    set -l cl_status $status
    if test $cl_status -ne 0
        commandline --function execute
        return
    end

    if not set -q _ISLAND_PROFILES[1]
        commandline --function execute
        return
    end

    if set -q _ISLAND_WRAPPED_CMDS[1]
        for cmd in $_ISLAND_WRAPPED_CMDS
            functions -e -- $cmd
        end
    end
    set -e _ISLAND_WRAPPED_CMDS
    set -g _ISLAND_WRAPPED_CMDS

    set -l buffer (commandline --current-buffer)
    set -l out ""
    set -l token ""
    set -l expecting_cmd 1
    set -l in_squote 0
    set -l in_dquote 0
    set -l escaped 0
    set -l in_comment 0
    set -l modified 0

    function _island_process_token --no-scope-shadowing --argument-names token_ref
        set -l raw_token $token_ref
        set -l stripped (string trim -- "$raw_token")
        if test -z "$stripped"
            return
        end

        set -l is_assignment 0
        if string match -r '^[A-Za-z_][A-Za-z0-9_]*[+]?=.*' -- $stripped
            set is_assignment 1
        end

        set -l is_sep_word 0
        if test "$stripped" = "and" -o "$stripped" = "or"
            set is_sep_word 1
        end

        if test $expecting_cmd -eq 1
            if test $is_assignment -eq 1
                set out "$out$raw_token"
                return
            end
            if test $is_sep_word -eq 1
                set out "$out$raw_token"
                set expecting_cmd 1
                return
            end

            set -l name (string unescape -- "$stripped")

            if string match -r '/' -- "$name"
                set out "$out""island run -- $raw_token"
                set modified 1
            else
                _island_wrap_cmd "$name"
                set out "$out$raw_token"
            end
            set expecting_cmd 0
        else
            if test $is_sep_word -eq 1
                set expecting_cmd 1
            end
            set out "$out$raw_token"
        end
    end

    set -l i 1
    set -l len (string length -- $buffer)
    while test $i -le $len
        set -l ch (string sub -s $i -l 1 -- $buffer)

        if test $in_comment -eq 1
            set out "$out$ch"
            if test "$ch" = "\n"
                set in_comment 0
                set expecting_cmd 1
            end
            set i (math $i + 1)
            continue
        end

        if test $escaped -eq 1
            set token "$token$ch"
            set escaped 0
            set i (math $i + 1)
            continue
        end

        if test "$ch" = "\\" -a $in_squote -eq 0
            set escaped 1
            set token "$token$ch"
            set i (math $i + 1)
            continue
        end

        if test "$ch" = "'" -a $in_dquote -eq 0
            set in_squote (math 1 - $in_squote)
            set token "$token$ch"
            set i (math $i + 1)
            continue
        end

        if test "$ch" = '"' -a $in_squote -eq 0
            set in_dquote (math 1 - $in_dquote)
            set token "$token$ch"
            set i (math $i + 1)
            continue
        end

        if test $in_squote -eq 0 -a $in_dquote -eq 0
            if test "$ch" = "#"
                if test -n "$token"
                    _island_process_token "$token"
                    set token ""
                end
                set out "$out#"
                set in_comment 1
                set i (math $i + 1)
                continue
            end

            set -l remaining (string sub -s $i -- $buffer)
            set -l sep_len 0
            set -l sep_value ""

            # Treat fd redirections like 2>| as separators.
            set -l match (string match -r "^[0-9]+>\\|" -- $remaining)
            if test (count $match) -gt 0
                set sep_value $match[1]
                set sep_len (string length -- $sep_value)
            else if string match -r '^&&' -- $remaining
                set sep_value "&&"
                set sep_len 2
            else if string match -r "^\\|\\|" -- $remaining
                set sep_value "||"
                set sep_len 2
            else if string match -r "^&\\|" -- $remaining
                set sep_value "&|"
                set sep_len 2
            else if test "$ch" = "|" -o "$ch" = ";" -o "$ch" = "&" -o "$ch" = "\n"
                set sep_value $ch
                set sep_len 1
            end

            if test $sep_len -gt 0
                if test -n "$token"
                    _island_process_token "$token"
                    set token ""
                end
                set out "$out$sep_value"
                set expecting_cmd 1
                set i (math $i + $sep_len)
                continue
            end
        end

        if test $in_squote -eq 0 -a $in_dquote -eq 0
            if string match -r '^[ \t\r]$' -- $ch
                if test -n "$token"
                    _island_process_token "$token"
                    set token ""
                end
                set out "$out$ch"
                set i (math $i + 1)
                continue
            end
        end

        set token "$token$ch"
        set i (math $i + 1)
    end

    if test -n "$token"
        _island_process_token "$token"
    end

    if test $modified -eq 1
        commandline --replace -- "$out"
    end

    commandline --function execute
end

function _island_precmd --on-event fish_prompt
    if not set -q _ISLAND_WRAPPED_CMDS[1]
        return 0
    end
    for cmd in $_ISLAND_WRAPPED_CMDS
        functions -e -- $cmd
    end
    set -e _ISLAND_WRAPPED_CMDS
end

function island
    command island $argv
    set -l ret $status
    _island_chpwd
    return $ret
end

function _island_unhook
    bind --erase \r
    bind -M insert --erase \r

    if functions -q _island_precmd
        _island_precmd
    end

    functions -e _island_accept_line
    functions -e _island_chpwd
    functions -e _island_precmd
    functions -e _island_unhook
    functions -e _island_wrap_cmd
    functions -e island

    set -e _ISLAND_PROFILES
    set -e _ISLAND_WRAPPED_CMDS
end

if status is-interactive
    bind \r _island_accept_line
    # Ensure insert-mode bindings (vi-mode) also intercept Enter.
    bind -M insert \r _island_accept_line
end

_island_chpwd
