#!/usr/bin/env bash

herdr_temp_create_owned_dir() {
  local root="$1"
  local prefix="$2"
  [[ "$prefix" =~ ^[a-z0-9-]+-$ ]] || return 1
  mkdir -p -- "$root"
  root="$(realpath -e -- "$root")" || return 1
  local owned_dir
  owned_dir="$(mktemp -d "$root/${prefix}XXXXXX")" || return 1
  touch "$owned_dir/.herdr-owned"
  printf '%s\n' "$owned_dir"
}

herdr_temp_remove_owned_dir() {
  local root="$1"
  local owned_dir="$2"
  local prefix="$3"
  [[ "$prefix" =~ ^[a-z0-9-]+-$ ]] || return 1
  root="$(realpath -e -- "$root")" || return 1
  [ -d "$owned_dir" ] || return 0
  local parent name
  parent="$(dirname -- "$owned_dir")"
  name="$(basename -- "$owned_dir")"
  [ "$parent" = "$root" ] || return 1
  [[ "$name" =~ ^${prefix}[A-Za-z0-9]+$ ]] || return 1
  [ -f "$owned_dir/.herdr-owned" ] || return 1
  rm -rf -- "$owned_dir"
}
