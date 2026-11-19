#!/bin/bash
# run-proxy.sh
set -euo pipefail

PROXY="$(cd "$(dirname "$0")" && pwd)/proxy.py"

usage() {
  cat >&2 <<'EOF'
Usage: run-proxy.sh [-c CONFIG.toml] [-s PROVIDER=ITEM]... [-a [PROVIDER=]ACCOUNT]... \
                    [-k [PROVIDER=]KEYCHAIN]... [-d PROVIDER]... [-e PROVIDER]... \
                    [-n] [-v] [-l] [-j] [-- proxy args...]

Config file
  -c, --config FILE        TOML file with the same settings as the options below
                           (env: PROXY_CONFIG). Flags and environment variables
                           always override it. See the sample proxy.toml.

Providers and keys
  -s PROVIDER=ITEM         Keychain item (service) for a provider. Repeatable.
  -a [PROVIDER=]ACCOUNT    Account name; per provider with PROVIDER=, else default.
  -k [PROVIDER=]KEYCHAIN   Keychain file or name; same rules.
  -d, --disable PROVIDER   Skip this provider in the launcher (no key is read).
  -e, --enable PROVIDER    Re-enable a provider disabled through the environment
                           or the config file.

Modes
  -l, --list-providers     Ask proxy.py which providers it supports, then exit.
  -n, --dry-run, --check, --verify
                           Report the status of EVERY provider proxy.py supports
                           (plus any you configured), and exit without starting
                           the proxy. Exit 0 if at least one provider would run,
                           1 if none would. Works with no -s flags.
  -v, --verbose            Print the provider table and the routes the proxy will
                           intercept (with -l: upstream URLs and allowed paths).
  -j, --json               JSON output for --list-providers and --check (stdout),
                           or for -v on a real run (stderr). For nushell/jtbl.

Status values
  ok              will run
  unconfigured    supported by proxy.py but no keychain item given (-s)
  disabled        disabled by the launcher (-d / KEYCHAIN_DISABLE / config)
  proxy_disabled  disabled in proxy.py
  nokey           keychain item not found or unreadable
  unknown         configured here but not supported by proxy.py

Environment (comma-separated lists of PROVIDER=value; a bare value is the default)
  PROXY_CONFIG        Path to the TOML config file (same as -c)
  KEYCHAIN_SERVICES   e.g. openai=openai-api-key,deepinfra=deepinfra-api-key
  KEYCHAIN_ACCOUNTS   e.g. alice,openai=bob
  KEYCHAIN_FILES      e.g. ~/Library/Keychains/agent.keychain-db,openai=login.keychain-db
  KEYCHAIN_DISABLE    e.g. openai,deepinfra
  KEYCHAIN_ACCOUNT    Default account for all providers (default: $USER)
  KEYCHAIN_FILE       Default keychain for all providers (default: search list)
  PROXY_VERBOSE       1/true/yes = same as -v

Precedence per provider and setting (config file values come last):
  provider flag > provider env > global flag > global env
    > provider config > global config > built-in default
  Any flag or environment variable beats anything in the config file.

A provider that can't run is skipped, not fatal; the rest still run.
Arguments after -- go to proxy.py (e.g. -- --port 9000 --disable openai).
EOF
  exit "${1:-1}"
}

# ---- long options -> short options (getopts only handles short ones) ----
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --)                           ARGS+=("$@"); break ;;
    --list-providers|--list)      ARGS+=(-l) ;;
    --dry-run|--check|--verify)   ARGS+=(-n) ;;
    --verbose)                    ARGS+=(-v) ;;
    --json)                       ARGS+=(-j) ;;
    --help)                       ARGS+=(-h) ;;
    --disable|--enable|--config)
      if [ $# -lt 2 ]; then echo "Error: $1 needs a value." >&2; usage; fi
      case "$1" in
        --disable) ARGS+=(-d "$2") ;;
        --enable)  ARGS+=(-e "$2") ;;
        --config)  ARGS+=(-c "$2") ;;
      esac
      shift ;;
    *)                            ARGS+=("$1") ;;
  esac
  shift
done
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

# ---- helpers ----
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

PROVIDERS=""   # providers configured via SVC (lowercase, space-separated)
MENTIONED=""   # providers named in any spec, to catch typos
# Global defaults from flags/env. Empty means "not set"; the config file and
# then the built-in default ($USER / keychain search list) fill in below.
G_ACC="${KEYCHAIN_ACCOUNT:-}"
G_KCH="${KEYCHAIN_FILE:-}"
CG_ACC=""      # global defaults from the config file
CG_KCH=""
CONFIG="${PROXY_CONFIG:-}"
CFG_VERBOSE=0
LIST=0
DRYRUN=0
JSON=""
VERBOSE=""
case "${PROXY_VERBOSE:-}" in 1|true|yes|on) VERBOSE=1 ;; esac

note_provider() {
  if ! in_list "$1" "$MENTIONED"; then MENTIONED="$MENTIONED $1"; fi
}

# apply KIND SPEC  (KIND is SVC, ACC or KCH): flags and environment
apply() {
  local kind="$1" spec="$2" name val
  if [[ "$spec" == *=* ]] && [[ "${spec%%=*}" =~ ^[A-Za-z0-9_]+$ ]]; then
    name="$(lower "${spec%%=*}")"
    val="${spec#*=}"
    if [ -z "$val" ]; then
      echo "Error: empty value in '$spec'." >&2
      exit 1
    fi
    printf -v "${kind}_$(upper "$name")" '%s' "$val"
    note_provider "$name"
    if [ "$kind" = SVC ] && ! in_list "$name" "$PROVIDERS"; then
      PROVIDERS="$PROVIDERS $name"
    fi
  else
    case "$kind" in
      SVC) echo "Error: bad -s '$spec' (expected provider=keychain-item)." >&2; exit 1 ;;
      ACC) G_ACC="$spec" ;;
      KCH) G_KCH="$spec" ;;
    esac
  fi
}

# apply_cfg KIND PROVIDER|- VALUE: values from the config file. These live in
# separate variables (CSVC_, CACC_, CKCH_, CDIS_) so any flag or env value wins.
apply_cfg() {
  local kind="$1" name="$2" val="$3"
  if [ "$name" = - ]; then
    case "$kind" in
      ACC) CG_ACC="$val" ;;
      KCH) CG_KCH="$val" ;;
      VERBOSE) CFG_VERBOSE=1 ;;
    esac
    return 0
  fi
  if ! [[ "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Error: bad provider name '$name' from config." >&2
    exit 1
  fi
  local P; P="$(upper "$name")"
  note_provider "$name"
  case "$kind" in
    SVC)
      printf -v "CSVC_$P" '%s' "$val"
      if ! in_list "$name" "$PROVIDERS"; then PROVIDERS="$PROVIDERS $name"; fi ;;
    ACC) printf -v "CACC_$P" '%s' "$val" ;;
    KCH) printf -v "CKCH_$P" '%s' "$val" ;;
    DIS) printf -v "CDIS_$P" '%s' "$val" ;;
  esac
}

split_env() {
  local kind="$1" value="$2" items item
  if [ -n "$value" ]; then
    IFS=',' read -r -a items <<< "$value"
    for item in "${items[@]}"; do apply "$kind" "$item"; done
  fi
}

# set_disabled NAME 1|0
set_disabled() {
  local name="${1// /}"
  if ! [[ "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Error: bad provider name '$1' for disable/enable." >&2
    exit 1
  fi
  printf -v "DIS_$(upper "$name")" '%s' "$2"
}

# ---- environment first, then flags, so flags override ----
split_env SVC "${KEYCHAIN_SERVICES:-}"
split_env ACC "${KEYCHAIN_ACCOUNTS:-}"
split_env KCH "${KEYCHAIN_FILES:-}"
if [ -n "${KEYCHAIN_DISABLE:-}" ]; then
  IFS=',' read -r -a _dis <<< "$KEYCHAIN_DISABLE"
  for item in "${_dis[@]}"; do set_disabled "$item" 1; done
fi

while getopts "c:s:a:k:d:e:lnvjh" opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    s) apply SVC "$OPTARG" ;;
    a) apply ACC "$OPTARG" ;;
    k) apply KCH "$OPTARG" ;;
    d) set_disabled "$OPTARG" 1 ;;
    e) set_disabled "$OPTARG" 0 ;;
    l) LIST=1 ;;
    n) DRYRUN=1 ;;
    v) VERBOSE=1 ;;
    j) JSON=1 ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# ---- config file (lowest precedence; proxy.py parses and validates the TOML) ----
CFGARGS=()
if [ -n "$CONFIG" ]; then
  CFGARGS=(--config "$CONFIG")
  if ! CFGOUT="$(python3 "$PROXY" --print-launcher-config "${CFGARGS[@]}")"; then
    echo "Error: could not load config file '$CONFIG'." >&2
    exit 1
  fi
  while IFS=$'\t' read -r _kind _name _val; do
    if [ -n "$_kind" ]; then apply_cfg "$_kind" "$_name" "$_val"; fi
  done <<< "$CFGOUT"
  if [ -z "$VERBOSE" ] && [ "$CFG_VERBOSE" = 1 ]; then VERBOSE=1; fi
fi

# ---- list mode: ask proxy.py ----
if [ "$LIST" = 1 ]; then
  exec python3 "$PROXY" --list-providers ${CFGARGS[@]+"${CFGARGS[@]}"} \
    ${VERBOSE:+--verbose} ${JSON:+--json} "$@"
fi

# Providers proxy.py supports, and which of them it has disabled
# (proxy args are passed too, so --disable/--enable, PROXY_DISABLE and the
# config file's [proxy] section apply)
if ! LISTING="$(python3 "$PROXY" --list-providers --verbose ${CFGARGS[@]+"${CFGARGS[@]}"} "$@")"; then
  echo "Error: could not get the provider list from $PROXY." >&2
  exit 1
fi
KNOWN=""; PDIS=""
while IFS=$'\t' read -r n st _rest; do
  if [ -n "$n" ]; then
    KNOWN="$KNOWN $n"
    if [ "$st" = disabled ]; then PDIS="$PDIS $n"; fi
  fi
done <<< "$LISTING"

# Never inherit keys from the caller's environment; only validated ones are exported
for k in $KNOWN; do unset "UPSTREAM_KEY_$(upper "$k")"; done

# A real run needs at least one configured provider; --check just reports
if [ "$DRYRUN" = 0 ] && [ -z "${PROVIDERS// /}" ]; then
  echo "Error: no providers configured (use -s, KEYCHAIN_SERVICES or a config file)." >&2
  usage
fi

for name in $MENTIONED; do
  if ! in_list "$name" "$PROVIDERS"; then
    echo "Warning: '$name' has an account/keychain setting but no item; ignoring." >&2
  fi
done

# Every supported provider, plus anything configured that proxy.py doesn't know
ALL="$KNOWN"
for name in $PROVIDERS; do
  if ! in_list "$name" "$KNOWN"; then ALL="$ALL $name"; fi
done

# ---- resolve every provider; skip (don't fail) the ones that can't run ----
R_NAME=(); R_ITEM=(); R_ACC=(); R_KCH=(); R_STATE=(); R_MSG=()
RUNNABLE=0

for name in $ALL; do
  P="$(upper "$name")"
  # item: flag/env, then config
  v="SVC_$P"; service="${!v:-}"
  if [ -z "$service" ]; then v="CSVC_$P"; service="${!v:-}"; fi
  # account: provider flag/env > global flag/env > provider config > global config > $USER
  v="ACC_$P"; account="${!v:-}"
  if [ -z "$account" ]; then account="$G_ACC"; fi
  if [ -z "$account" ]; then v="CACC_$P"; account="${!v:-}"; fi
  if [ -z "$account" ]; then account="$CG_ACC"; fi
  if [ -z "$account" ]; then account="${USER:-$(id -un)}"; fi
  # keychain: same order, default is the search list (empty)
  v="KCH_$P"; keychain="${!v:-}"
  if [ -z "$keychain" ]; then keychain="$G_KCH"; fi
  if [ -z "$keychain" ]; then v="CKCH_$P"; keychain="${!v:-}"; fi
  if [ -z "$keychain" ]; then keychain="$CG_KCH"; fi
  # disabled: flag/env (-d/-e), then config
  v="DIS_$P"; disabled="${!v:-}"
  if [ -z "$disabled" ]; then v="CDIS_$P"; disabled="${!v:-0}"; fi
  state="ok"; msg="will run"

  if ! in_list "$name" "$KNOWN"; then
    state="unknown"; msg="skipped: not supported by proxy.py"
  elif [ "$disabled" = 1 ]; then
    state="disabled"; msg="skipped: disabled by launcher"
  elif in_list "$name" "$PDIS"; then
    state="proxy_disabled"; msg="skipped: disabled in proxy.py"
  elif [ -z "$service" ]; then
    state="unconfigured"; msg="skipped: no keychain item (use -s $name=ITEM)"
  else
    CMD=(security find-generic-password -a "$account" -s "$service" -w)
    if [ -n "$keychain" ]; then CMD+=("$keychain"); fi
    if value="$("${CMD[@]}" 2>/dev/null)" && [ -n "$value" ]; then
      export "UPSTREAM_KEY_$P=$value"
      RUNNABLE=$((RUNNABLE + 1))
    else
      state="nokey"; msg="skipped: key not found or unreadable"
    fi
  fi
  value=""

  R_NAME+=("$name"); R_ITEM+=("$service"); R_ACC+=("$account")
  R_KCH+=("$keychain"); R_STATE+=("$state"); R_MSG+=("$msg")
done

print_table() {
  local i
  printf '%-12s %-24s %-14s %-28s %s\n' PROVIDER ITEM ACCOUNT KEYCHAIN STATUS
  for i in "${!R_NAME[@]}"; do
    printf '%-12s %-24s %-14s %-28s %s\n' \
      "${R_NAME[$i]}" "${R_ITEM[$i]:--}" "${R_ACC[$i]}" "${R_KCH[$i]:-(default)}" "${R_MSG[$i]}"
  done
}

# Flat array of objects: works with `from json` (nushell) and jtbl
print_json() {
  local i n=${#R_NAME[@]} sep="," will item kch
  echo "["
  for i in "${!R_NAME[@]}"; do
    if [ $((i + 1)) -eq "$n" ]; then sep=""; fi
    if [ "${R_STATE[$i]}" = ok ]; then will=true; else will=false; fi
    if [ -n "${R_ITEM[$i]}" ]; then item="\"$(json_escape "${R_ITEM[$i]}")\""; else item=null; fi
    if [ -n "${R_KCH[$i]}" ]; then kch="\"$(json_escape "${R_KCH[$i]}")\""; else kch=null; fi
    printf '  {"provider": "%s", "item": %s, "account": "%s", "keychain": %s, "status": "%s", "will_run": %s, "message": "%s"}%s\n' \
      "$(json_escape "${R_NAME[$i]}")" "$item" "$(json_escape "${R_ACC[$i]}")" \
      "$kch" "${R_STATE[$i]}" "$will" "$(json_escape "${R_MSG[$i]}")" "$sep"
  done
  echo "]"
}

# ---- dry run ----
if [ "$DRYRUN" = 1 ]; then
  if [ -n "$JSON" ]; then
    print_json
  else
    print_table
    echo
    if [ "$RUNNABLE" -eq 0 ]; then
      echo "Result: no providers would run."
    else
      echo "Result: $RUNNABLE of ${#R_NAME[@]} provider(s) would run."
    fi
  fi
  if [ "$RUNNABLE" -eq 0 ]; then exit 1; fi
  python3 "$PROXY" --dry-run ${CFGARGS[@]+"${CFGARGS[@]}"} ${VERBOSE:+--verbose} "$@"
  exit 0
fi

# ---- real run ----
for i in "${!R_NAME[@]}"; do
  case "${R_STATE[$i]}" in
    unknown|nokey) echo "Warning: [${R_NAME[$i]}] ${R_MSG[$i]}" >&2 ;;
  esac
done

if [ "$RUNNABLE" -eq 0 ]; then
  if [ -n "$JSON" ]; then print_json >&2; else print_table >&2; fi
  echo "Error: no providers can run; nothing to proxy." >&2
  exit 1
fi

if [ -n "$VERBOSE" ]; then
  if [ -n "$JSON" ]; then print_json >&2; else print_table >&2; fi
fi

exec python3 "$PROXY" ${CFGARGS[@]+"${CFGARGS[@]}"} ${VERBOSE:+--verbose} "$@"
