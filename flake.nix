{
  description = "Credential-injecting LLM proxy (macOS keychain launcher + aiohttp proxy)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        llm-credential-proxy = pkgs.callPackage ./package.nix { };
        default = llm-credential-proxy;
      });

      # `nix run` (launcher, the default) and `nix run .#proxy` (proxy.py alone)
      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/run-proxy";
        };
        proxy = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/credential-proxy";
        };
      });

      # Adds pkgs.llm-credential-proxy to any nixpkgs, for NixOS, nix-darwin
      # and home-manager configurations.
      overlays.default = final: _prev: {
        llm-credential-proxy = final.callPackage ./package.nix { };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.python3.withPackages (ps: [ ps.aiohttp ps.toml ]))
            pkgs.shellcheck
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
