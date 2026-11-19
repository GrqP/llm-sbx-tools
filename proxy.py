#!/usr/bin/env python3
"""Credential-injecting multi-provider proxy.

Sits between a sandboxed agent and upstream LLM APIs. The agent sends requests
with no real credentials; the proxy injects the real key and forwards them.
Keys are read from UPSTREAM_KEY_<PROVIDER> environment variables, normally set
by run-proxy.sh from the macOS keychain. A provider with no key, or that is
disabled, is not served and its prefix returns 404.

ROUTING
  http://<host>:<port>/<provider>/<upstream path>

  Provider    Prefix        Allowed upstream paths
  ----------  ------------  ---------------------------------------------
  openrouter  /openrouter   /api/v1/chat/completions
  openai      /openai       /v1/chat/completions, /v1/responses, /v1/embeddings
  anthropic   /anthropic    /v1/messages
  deepinfra   /deepinfra    /v1/openai/chat/completions, /v1/openai/embeddings

  Only POST to the exact allowed paths is forwarded (everything else: 403).
  Client-supplied auth headers are discarded.

CLIENT BASE URLS (from a Docker container; use any dummy API key)
  OpenRouter  http://host.docker.internal:8080/openrouter/api/v1
  OpenAI      http://host.docker.internal:8080/openai/v1
  Anthropic   http://host.docker.internal:8080/anthropic
  DeepInfra   http://host.docker.internal:8080/deepinfra/v1/openai

OPTIONS (flag > environment variable > config file > default)
  -c, --config FILE TOML config file  env PROXY_CONFIG   (see CONFIG FILE)
  -H, --host        IP to bind         env PROXY_HOST     default 127.0.0.1
  -p, --port        Port to listen on  env PROXY_PORT     default 8080
  -v, --verbose     Dump the providers/routes the proxy intercepts
                                       env PROXY_VERBOSE  (1/true/yes)
      --disable P   Disable provider P (repeatable, or comma-separated)
                                       env PROXY_DISABLE  (comma-separated)
      --enable P    Enable provider P  (repeatable)
                                       env PROXY_ENABLE   (comma-separated)
      --list-providers  Print supported provider names, one per line
                        with -v:    tab-separated name, enabled|disabled,
                                    upstream URL, allowed paths
                        with --json: JSON array (add -v for upstream and paths)
      --json        JSON output for --list-providers
      --dry-run     Check keys and imports, show what would run, then exit

CONFIG FILE (TOML; needs Python 3.11+, or `pip install tomli`)
  [proxy]     host, port, verbose, disable, enable   (same as the options)
  [keychain]  account, file                          (used by run-proxy.sh)
  [providers.NAME]  item, account, keychain, enabled (used by run-proxy.sh)
  Flags and environment variables always override the file. It must never
  contain API keys. See the sample proxy.toml.

DISABLING A PROVIDER (later steps override earlier ones)
  1. In code:  add  "enabled": False  to its PROVIDERS entry
  2. Config:   [proxy] disable = ["openai"]   enable = ["deepinfra"]
  3. Env:      PROXY_DISABLE=openai,deepinfra   PROXY_ENABLE=openai
  4. Flags:    --disable openai --enable deepinfra
  Disabled providers are never served, even if a key is present.

KEYS
  UPSTREAM_KEY_OPENROUTER, UPSTREAM_KEY_OPENAI,
  UPSTREAM_KEY_ANTHROPIC,  UPSTREAM_KEY_DEEPINFRA
  Run via run-proxy.sh rather than setting these by hand.

EXAMPLES
  ./run-proxy.sh -s deepinfra=deepinfra-api-key
  ./run-proxy.sh -s openai=openai-api-key -- --port 9000
  ./run-proxy.sh -s openai=k1 -s deepinfra=k2 -- --disable openai
  ./run-proxy.sh --config proxy.toml
  python3 proxy.py --list-providers --json

ADDING A PROVIDER
  Add an entry to PROVIDERS below: upstream URL, allowed paths, and a lambda
  that builds the auth header (optionally "enabled": False). The provider name
  is the URL prefix and the suffix of its UPSTREAM_KEY_ variable.

SECURITY NOTES
  - Keep the default 127.0.0.1 bind. The proxy has no client authentication.
  - Use dedicated, spend-limited keys for each provider.
"""
import argparse
import json
import os
import re
import sys

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8080

PROVIDERS = {
    "openrouter": {
        "upstream": "https://openrouter.ai",
        "allowed": {"/api/v1/chat/completions"},
        "auth": lambda k: {"Authorization": f"Bearer {k}"},
        # "enabled": False,   # uncomment to disable by default
    },
    "openai": {
        "upstream": "https://api.openai.com",
        "allowed": {"/v1/chat/completions", "/v1/responses", "/v1/embeddings"},
        "auth": lambda k: {"Authorization": f"Bearer {k}"},
    },
    "anthropic": {
        "upstream": "https://api.anthropic.com",
        "allowed": {"/v1/messages"},
        "auth": lambda k: {"x-api-key": k},
        "defaults": {"anthropic-version": "2023-06-01"},
        "passthrough": ("anthropic-version", "anthropic-beta"),
    },
    "deepinfra": {
        "upstream": "https://api.deepinfra.com",
        "allowed": {"/v1/openai/chat/completions", "/v1/openai/embeddings"},
        "auth": lambda k: {"Authorization": f"Bearer {k}"},
    },
}


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").lower() in ("1", "true", "yes", "on")


def first(*values):
    """First value that is neither None nor an empty string."""
    for v in values:
        if v is not None and v != "":
            return v
    return None


def split_names(values) -> list:
    """Flatten ['a,b', 'c'] into ['a', 'b', 'c'], lowercased."""
    out = []
    for v in values:
        out.extend(x.strip().lower() for x in v.split(",") if x.strip())
    return out


# ---------------------------------------------------------------- config file

CONFIG_SCHEMA = {
    "proxy": {"host": str, "port": int, "verbose": bool, "disable": list, "enable": list},
    "keychain": {"account": str, "file": str},
}
PROVIDER_SCHEMA = {"item": str, "account": str, "keychain": str, "enabled": bool}
SECRET_KEYS = {"key", "api_key", "apikey", "secret", "token", "password"}
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


def _die(path, msg):
    sys.exit(f"Config error ({path}): {msg}")


def _check_table(path, where, table, schema):
    if not isinstance(table, dict):
        _die(path, f"[{where}] must be a table")
    for key, value in table.items():
        if key.lower() in SECRET_KEYS:
            _die(path, f"'{key}' in [{where}]: keys must not be stored in the config; "
                       "use a keychain item name ('item') instead")
        if key not in schema:
            print(f"WARNING: {path}: unknown setting '{key}' in [{where}] (ignored).",
                  file=sys.stderr)
            continue
        want = schema[key]
        # bool is a subclass of int, so reject it explicitly for ints
        ok = isinstance(value, want) and not (want is int and isinstance(value, bool))
        if want is list and isinstance(value, str):     # "a,b" is accepted for lists
            table[key] = value = [value]
            ok = True
        if not ok:
            _die(path, f"[{where}] {key} must be a {want.__name__}")
        if want is list and not all(isinstance(x, str) for x in value):
            _die(path, f"[{where}] {key} must be a list of strings")
        if want is str:
            if not value.strip():
                _die(path, f"[{where}] {key} must not be empty")
            if any(c in value for c in "\t\r\n"):
                _die(path, f"[{where}] {key} must not contain tabs or newlines")


def load_config(path) -> dict:
    """Load and validate the TOML config. Returns {} when no path is given."""
    if not path:
        return {}
    path = os.path.expanduser(path)
    try:
        import tomllib
    except ModuleNotFoundError:
        try:
            import tomli as tomllib
        except ModuleNotFoundError:
            sys.exit("Config files need Python 3.11+ (tomllib) or the 'tomli' package "
                     "(pip install tomli).")
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
    except OSError as e:
        sys.exit(f"Cannot read config file {path}: {e.strerror}")
    except tomllib.TOMLDecodeError as e:
        sys.exit(f"Config file {path} is not valid TOML: {e}")

    for section, value in cfg.items():
        if section in CONFIG_SCHEMA:
            _check_table(path, section, value, CONFIG_SCHEMA[section])
        elif section == "providers":
            if not isinstance(value, dict):
                _die(path, "[providers] must be a table of tables")
            for name, table in value.items():
                if not NAME_RE.match(name):
                    _die(path, f"bad provider name '{name}'")
                _check_table(path, f"providers.{name}", table, PROVIDER_SCHEMA)
        else:
            print(f"WARNING: {path}: unknown section [{section}] (ignored).", file=sys.stderr)

    port = cfg.get("proxy", {}).get("port")
    if port is not None and not (1 <= port <= 65535):
        _die(path, f"[proxy] port must be between 1 and 65535, got {port}")
    cfg["_path"] = path
    return cfg


def print_launcher_config(cfg: dict) -> None:
    """Emit settings for run-proxy.sh as tab-separated KIND, PROVIDER|-, VALUE lines."""
    def emit(kind, provider, value):
        print(f"{kind}\t{provider}\t{value}")

    kc = cfg.get("keychain", {})
    if "account" in kc:
        emit("ACC", "-", kc["account"])
    if "file" in kc:
        emit("KCH", "-", os.path.expanduser(kc["file"]))
    for name, p in cfg.get("providers", {}).items():
        n = name.lower()
        if "item" in p:
            emit("SVC", n, p["item"])
        if "account" in p:
            emit("ACC", n, p["account"])
        if "keychain" in p:
            emit("KCH", n, os.path.expanduser(p["keychain"]))
        if "enabled" in p:
            emit("DIS", n, "0" if p["enabled"] else "1")
    if cfg.get("proxy", {}).get("verbose"):
        emit("VERBOSE", "-", "1")


# ------------------------------------------------------------------- options

def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Defaults are None so we can tell "not given" from "given" and layer
    # flag > env > config > default in resolve_options().
    p.add_argument("-c", "--config", metavar="FILE", default=None,
                   help="TOML config file (env: PROXY_CONFIG); flags and env override it")
    p.add_argument("-H", "--host", default=None,
                   help=f"IP address to bind (env: PROXY_HOST, default: {DEFAULT_HOST})")
    p.add_argument("-p", "--port", type=int, default=None,
                   help=f"Port to listen on (env: PROXY_PORT, default: {DEFAULT_PORT})")
    p.add_argument("-v", "--verbose", action="store_true", default=None,
                   help="Dump the providers and routes the proxy intercepts (env: PROXY_VERBOSE)")
    p.add_argument("--disable", action="append", default=[], metavar="PROVIDER",
                   help="Disable a provider (repeatable; env: PROXY_DISABLE)")
    p.add_argument("--enable", action="append", default=[], metavar="PROVIDER",
                   help="Enable a provider, overriding code/config/env defaults (env: PROXY_ENABLE)")
    p.add_argument("--list-providers", action="store_true",
                   help="Print supported provider names and exit (-v for details)")
    p.add_argument("--json", action="store_true",
                   help="JSON output for --list-providers")
    p.add_argument("--dry-run", action="store_true",
                   help="Check keys and imports, show what would run, then exit")
    p.add_argument("--print-launcher-config", action="store_true",
                   help=argparse.SUPPRESS)   # internal: used by run-proxy.sh
    return p.parse_args()


def resolve_options(args, cfg: dict) -> None:
    """Fill host/port/verbose: flag > env > config > default."""
    pc = cfg.get("proxy", {})
    args.host = first(args.host, os.environ.get("PROXY_HOST"), pc.get("host"), DEFAULT_HOST)

    raw = first(args.port, os.environ.get("PROXY_PORT"), pc.get("port"), DEFAULT_PORT)
    try:
        args.port = int(raw)
    except (TypeError, ValueError):
        sys.exit(f"Invalid port: {raw!r}")
    if not (1 <= args.port <= 65535):
        sys.exit(f"port must be between 1 and 65535, got {args.port}")

    if args.verbose is None:
        if os.environ.get("PROXY_VERBOSE"):
            args.verbose = env_flag("PROXY_VERBOSE")
        else:
            args.verbose = bool(pc.get("verbose", False))


def resolve_state(args, cfg: dict, warn: bool = True) -> dict:
    """Return {provider: (enabled, source)}; source is code, config, env or flag."""
    state = {n: (c.get("enabled", True), "code") for n, c in PROVIDERS.items()}

    def apply(names, value, source):
        for n in names:
            if n in state:
                state[n] = (value, source)
            elif warn:
                print(f"WARNING: unknown provider '{n}' in {source} enable/disable list.",
                      file=sys.stderr)

    pc = cfg.get("proxy", {})
    apply(split_names(pc.get("disable", [])), False, "config")
    apply(split_names(pc.get("enable", [])), True, "config")
    apply(split_names([os.environ.get("PROXY_DISABLE", "")]), False, "env")
    apply(split_names([os.environ.get("PROXY_ENABLE", "")]), True, "env")
    apply(split_names(args.disable), False, "flag")
    apply(split_names(args.enable), True, "flag")
    return state


def list_providers(state: dict, verbose: bool, as_json: bool) -> None:
    rows = []
    for name in sorted(PROVIDERS):
        cfg = PROVIDERS[name]
        enabled, source = state[name]
        row = {"name": name, "enabled": enabled, "disabled_by": None if enabled else source}
        if verbose:
            row["upstream"] = cfg["upstream"]
            row["allowed_paths"] = sorted(cfg["allowed"])
        rows.append(row)

    if as_json:
        print(json.dumps(rows, indent=2))
    elif verbose:
        for r in rows:
            print("\t".join([r["name"], "enabled" if r["enabled"] else "disabled",
                             r["upstream"], ",".join(r["allowed_paths"])]))
    else:
        for r in rows:
            print(r["name"])


def load_keys(state: dict) -> dict:
    return {n: os.environ[f"UPSTREAM_KEY_{n.upper()}"]
            for n in PROVIDERS
            if state[n][0] and os.environ.get(f"UPSTREAM_KEY_{n.upper()}")}


def print_routes(keys: dict, state: dict, host: str, port: int) -> None:
    base = f"http://{host}:{port}"
    err = sys.stderr
    print("Intercepting:", file=err)
    for name in sorted(keys):
        cfg = PROVIDERS[name]
        print(f"  /{name}/  ->  {cfg['upstream']}", file=err)
        for path in sorted(cfg["allowed"]):
            print(f"      POST {base}/{name}{path}", file=err)
    disabled = [f"{n} ({state[n][1]})" for n in sorted(PROVIDERS) if not state[n][0]]
    if disabled:
        print(f"Disabled: {', '.join(disabled)}", file=err)
    nokey = sorted(n for n in PROVIDERS if state[n][0] and n not in keys)
    if nokey:
        print(f"Enabled but no key: {', '.join(nokey)}", file=err)


def make_app(keys: dict):
    from aiohttp import web, ClientSession

    async def handle(request):
        # /<provider>/<upstream path>
        parts = request.path.split("/", 2)
        if len(parts) < 3 or parts[1] not in keys:
            return web.Response(status=404)
        name = parts[1]
        cfg = PROVIDERS[name]
        path = "/" + parts[2]

        if request.method != "POST" or path not in cfg["allowed"]:
            return web.Response(status=403)

        # Build headers from scratch: client-supplied auth is never forwarded
        headers = {"Content-Type": "application/json"}
        headers.update(cfg.get("defaults", {}))
        for h in cfg.get("passthrough", ()):
            if h in request.headers:
                headers[h] = request.headers[h]
        headers.update(cfg["auth"](keys[name]))

        url = cfg["upstream"] + path
        if request.query_string:
            url += "?" + request.query_string

        body = await request.read()
        async with ClientSession() as s:
            async with s.post(url, data=body, headers=headers) as r:
                resp = web.StreamResponse(
                    status=r.status,
                    headers={"Content-Type": r.headers.get("Content-Type", "application/json")},
                )
                await resp.prepare(request)
                async for chunk in r.content.iter_any():
                    await resp.write(chunk)
                await resp.write_eof()
                return resp

    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", handle)
    return app


def main() -> None:
    args = parse_args()
    cfg = load_config(first(args.config, os.environ.get("PROXY_CONFIG")))

    if args.print_launcher_config:
        print_launcher_config(cfg)
        return

    resolve_options(args, cfg)
    state = resolve_state(args, cfg, warn=not args.list_providers)

    if args.list_providers:
        list_providers(state, args.verbose, args.json)
        return

    keys = load_keys(state)
    if not keys:
        sys.exit("No enabled provider has an UPSTREAM_KEY_<PROVIDER> variable "
                 "(run via run-proxy.sh).")
    if cfg.get("_path"):
        print(f"Config: {cfg['_path']}", file=sys.stderr)
    print(f"Enabled providers: {', '.join(sorted(keys))}", file=sys.stderr)
    if args.verbose:
        print_routes(keys, state, args.host, args.port)
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print(f"WARNING: binding to {args.host}; reachable from other machines.", file=sys.stderr)

    if args.dry_run:
        try:
            import aiohttp  # noqa: F401
        except ImportError:
            sys.exit("Dry run failed: aiohttp is not installed (pip install aiohttp).")
        print(f"Dry run OK: would listen on {args.host}:{args.port}", file=sys.stderr)
        return

    from aiohttp import web
    web.run_app(make_app(keys), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
