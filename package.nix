# package.nix: derivation for the credential-injecting LLM proxy.
# Called from flake.nix with callPackage, but also usable without flakes:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./package.nix {}'
{
  lib,
  stdenv,
  makeWrapper,
  python3,
  coreutils,
  gnused,
}:

let
  # proxy.py imports aiohttp lazily; tomllib is built in from Python 3.11,
  # older interpreters need tomli for --config.
  pythonEnv = python3.withPackages (
    ps: [ ps.aiohttp ] ++ lib.optional (python3.pythonOlder "3.11") ps.tomli
  );
in
stdenv.mkDerivation {
  pname = "llm-credential-proxy";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./proxy.py
      ./run-proxy.sh
      ./proxy.toml
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  # Makes patchShebangs point proxy.py at the interpreter that has aiohttp.
  buildInputs = [ pythonEnv ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # run-proxy.sh locates proxy.py next to itself, so keep them together.
    install -Dm755 proxy.py     $out/libexec/llm-credential-proxy/proxy.py
    install -Dm755 run-proxy.sh $out/libexec/llm-credential-proxy/run-proxy.sh
    install -Dm644 proxy.toml   $out/share/doc/llm-credential-proxy/proxy.toml.example

    # Launcher: python3 (with aiohttp) and coreutils/sed come from the store.
    # /usr/bin is only a *suffix*, so macOS's `security` (the keychain CLI,
    # which Nix cannot provide) is found without overriding anything above.
    makeWrapper $out/libexec/llm-credential-proxy/run-proxy.sh $out/bin/run-proxy \
      --prefix PATH : ${
        lib.makeBinPath [
          pythonEnv
          coreutils
          gnused
        ]
      } \
      --suffix PATH : /usr/bin

    # The proxy on its own (keys then come from UPSTREAM_KEY_* variables).
    ln -s $out/libexec/llm-credential-proxy/proxy.py $out/bin/credential-proxy

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    ${pythonEnv}/bin/python -c 'import aiohttp'
    $out/bin/credential-proxy --list-providers | grep -qx openai
    $out/bin/run-proxy --list-providers --json | grep -q '"name": "anthropic"'
    $out/bin/credential-proxy --print-launcher-config \
      --config $out/share/doc/llm-credential-proxy/proxy.toml.example | grep -q openai-api-key

    runHook postInstallCheck
  '';

  meta = {
    description = "Credential-injecting proxy that keeps LLM API keys out of sandboxed agents";
    longDescription = ''
      Reads API keys from the macOS keychain (run-proxy) and injects them into
      requests forwarded to OpenRouter, OpenAI, Anthropic and DeepInfra, so an
      agent in a container only ever holds a dummy key.
    '';
    mainProgram = "run-proxy";
    platforms = lib.platforms.unix;
  };
}
