#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --flavor <dev|prod> [--profile <profile>] [--runtime-mode <standard|offline>] [--env-file <path>]" >&2
}

flavor=''
profile=''
env_file=''
runtime_mode='standard'
while (($#)); do
  case "$1" in
    --flavor)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      flavor="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      profile="$2"
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      env_file="$2"
      shift 2
      ;;
    --runtime-mode)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      runtime_mode="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$flavor" in
  dev)
    expected_profile='local_dev'
    default_env_file='.dev.env'
    ;;
  prod)
    expected_profile='mobile_beta'
    default_env_file='.env'
    ;;
  *)
    echo "ERROR: unsupported mobile flavor '${flavor:-<missing>}' (expected dev or prod)." >&2
    exit 1
    ;;
esac

case "$runtime_mode" in
  standard|offline) ;;
  *)
    echo "ERROR: unsupported runtime mode '$runtime_mode' (expected standard or offline)." >&2
    exit 1
    ;;
esac

if [[ "$runtime_mode" == 'offline' && ( "$flavor" != 'dev' || "$expected_profile" != 'local_dev' ) ]]; then
  echo "ERROR: offline runtime requires flavor=dev and profile=local_dev." >&2
  exit 1
fi

if [[ -n "$profile" && "$profile" != "$expected_profile" ]]; then
  echo "ERROR: mobile flavor '$flavor' requires OMI_APP_PROFILE=$expected_profile, got '$profile'." >&2
  exit 1
fi

env_file="${env_file:-$default_env_file}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: missing $env_file; run setup_app_env $expected_profile before building." >&2
  exit 1
fi

read_setting() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { value = $2 } END { print value }' "$env_file"
}

for key in USE_WEB_AUTH USE_AUTH_CUSTOM_TOKEN; do
  if [[ "$(read_setting "$key")" != 'true' ]]; then
    echo "ERROR: $env_file must contain $key=true for the supported $flavor/$expected_profile mobile build." >&2
    exit 1
  fi
done

if [[ "$runtime_mode" == 'offline' ]]; then
  api_base_url="$(read_setting API_BASE_URL)"
  host="$(printf '%s' "$api_base_url" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#')"
  if [[ "$host" == "$api_base_url" || -z "$host" ]]; then
    echo "ERROR: $env_file must contain a valid local API_BASE_URL for offline runtime." >&2
    exit 1
  fi
  if [[ "$host" != 'localhost' && "$host" != '::1' && ! "$host" =~ ^127\. && ! "$host" =~ ^10\. && ! "$host" =~ ^192\.168\. && ! "$host" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. && ! "$host" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
    echo "ERROR: offline runtime requires API_BASE_URL to use a loopback/private host." >&2
    exit 1
  fi
fi

echo "mobile build config valid: flavor=$flavor profile=$expected_profile runtime=$runtime_mode env=$env_file"
