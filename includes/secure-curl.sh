#!/usr/bin/env bash

if [ -n "${_AAP_DEMO_SECURE_CURL_LOADED:-}" ]; then return 0; fi
_AAP_DEMO_SECURE_CURL_LOADED=1

curl() {
  local credentials="" authorization="" payload="" payload_option="" escaped config=""
  local -a arguments=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u | --user)
        [ "$#" -ge 2 ] || {
          printf 'curl: option %s requires an argument\n' "$1" >&2
          return 2
        }
        credentials="$2"
        shift 2
        ;;
      --user=*)
        credentials="${1#*=}"
        shift
        ;;
      -H | --header)
        [ "$#" -ge 2 ] || {
          printf 'curl: option %s requires an argument\n' "$1" >&2
          return 2
        }
        if [[ "$2" == Authorization:* ]]; then
          authorization="$2"
        else
          arguments+=("$1" "$2")
        fi
        shift 2
        ;;
      --header=Authorization:*)
        authorization="${1#*=}"
        shift
        ;;
      -d | --data | --data-raw | --data-binary | --json)
        [ "$#" -ge 2 ] || {
          printf 'curl: option %s requires an argument\n' "$1" >&2
          return 2
        }
        payload="$2"
        payload_option="$1"
        shift 2
        if [ "$payload" = "@-" ]; then
          payload=$(cat)
        fi
        ;;
      *)
        arguments+=("$1")
        shift
        ;;
    esac
  done

  if [ -z "$credentials" ] && [ -z "$authorization" ] && [ -z "$payload_option" ]; then
    command curl "${arguments[@]}"
    return
  fi

  if [ -n "$credentials" ]; then
    case "$credentials" in
      *$'\n'* | *$'\r'*)
        printf 'curl: credentials must not contain newlines\n' >&2
        return 2
        ;;
    esac
    escaped=${credentials//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    config+="user = \"${escaped}\""$'\n'
  fi
  if [ -n "$authorization" ]; then
    case "$authorization" in
      *$'\n'* | *$'\r'*)
        printf 'curl: authorization header must not contain newlines\n' >&2
        return 2
        ;;
    esac
    escaped=${authorization//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    config+="header = \"${escaped}\""$'\n'
  fi

  if [ -n "$payload_option" ]; then
    case "$payload_option" in
      --json)
        arguments+=(--json @/dev/fd/3)
        ;;
      *)
        arguments+=(--data-binary @/dev/fd/3)
        ;;
    esac
    printf '%s' "$config" | command curl --config - "${arguments[@]}" \
      3< <(printf '%s' "$payload")
  else
    printf '%s' "$config" | command curl --config - "${arguments[@]}"
  fi
}
