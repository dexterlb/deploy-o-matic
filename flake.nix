{
  description = "Opinionated wrapper for deployment tools";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }: {
    lib.deployOMatic = { templatesDir, overlaysDir ? null, overlays ? [], moduleArgs ? {}, nixpkgsConfig ? {}, ... }:
      let
        # get all templates, and from there get all hosts (≥1 hosts per template, usually 1)
        templateNames = dirsInDir templatesDir;
        hostList = builtins.concatLists (map hostsByTemplateName templateNames);
        hosts = mkHostMap hostList;
        hostsBySystem = system:
          mkHostMap (builtins.filter (host: host.system == system) hostList);

        # build a nixos configuration for the given host
        mkNixos = host: lib.nixosSystem (nixosSystemArgs host);

        # build a bootable disk image for the host, if configured
        mkImage = host:
          # TODO: disko now has image generation support: https://github.com/nix-community/disko/blob/master/docs/disko-images.md
          # with this, image generation can be revamped to be more flexible and to support stuff like embedding secrets
          if host ? image then
            (mkNixos host).config.system.build.${host.image.format}
          else
            null;

        mkDeployer = { host, nativeSystem }: let
          pkgs = pkgsFor nativeSystem;
          sysderivation = mkNixos host;
          toplevel = sysderivation.config.system.build.toplevel;
          prefixCmd = if host.deploy ? sshUser && host.deploy.sshUser == "root" then "" else "sudo";
          sshStr = if host.deploy ? sshUser
            then "${host.deploy.sshUser}@${host.deploy.hostname}"
            else host.deploy.hostname;
        in if host ? deploy then
          pkgs.writeShellScriptBin "deploy-${host.hostname}" ''
            set -euo pipefail

            if [[ $# -ne 1 ]] || ! [[ "$1" =~ ^boot|switch$ ]]; then
              echo "usage: $0 (boot|switch)" >&2
              echo "deploys the system configuration of ${host.hostname} to ${host.deploy.hostname}" >&2
              exit 1
            fi

            echo "copying closure to ${host.hostname}" >&2
            ${pkgs.nix}/bin/nix copy --to "ssh://${sshStr}" "${toplevel}"

            echo "activating profile" >&2
            ${pkgs.openssh}/bin/ssh "${sshStr}" \
              "${prefixCmd} ${pkgs.bash}/bin/bash -c 'nix-env -p /nix/var/nix/profiles/system --set ${toplevel} && ${toplevel}/bin/switch-to-configuration $1'"
          ''
        else
          null;

        deployerPkgs = system: lib.attrsets.mapAttrs' (name: value:
          {
            name = "${name}-deploy";
            value = mkDeployer { host = value; nativeSystem = system; };
          }
        ) hosts;

        imagePkgs = system: lib.attrsets.mapAttrs' (name: value:
          {
            name = "${name}-image";
            inherit value;
          }
        ) (mapValuesIf mkImage (hostsBySystem system));

        nixosSystemArgs = host: {
          system = host.system;
          specialArgs = moduleArgs
            // (if host ? moduleArgs then host.moduleArgs else { });
          modules = [
            (templatesDir + "/${host.templateName}")
            {
              nixpkgs.overlays = allOverlays;
              nixpkgs.config = nixpkgsConfig;
            }
          ];
        };

        # the usual shit
        lib = nixpkgs.lib;

        allUsedSystems = lib.lists.unique (map (host: host.system) hostList);
        allSystems =
          [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
        forAllUsedSystems = lib.genAttrs allUsedSystems;
        forAllSystems = lib.genAttrs allSystems;
        pkgsFor = system:
          import nixpkgs {
            inherit system;
            overlays = allOverlays;
            config = nixpkgsConfig;
          };

        # nixpkgs overlays (used for custom package overrides)
        allOverlays = overlays ++ (if overlaysDir != null then overlaysIn overlaysDir else []);
        overlaysIn = dir: (map (src: import "${dir}/${src}") (overlaySourcesIn dir));
        overlaySourcesIn = dir: lib.attrNames (lib.filterAttrs
          (name: type: type == "directory" || lib.hasSuffix ".nix" name)
          (builtins.readDir dir));

        # gives a list of hosts from a single template
        hostsByTemplateName = name:
          let
            hostsFunc = import "${templatesDir}/${name}/hosts.nix";
            hostsData = hostsFunc {
              inherit nixpkgs hostsByTemplateName hosts;
            };
          in map (data: data // { templateName = name; }) hostsData;

        # util functions
        mkHostMap = hostList:
          builtins.listToAttrs (map (host: {
            name = host.hostname;
            value = host;
          }) hostList);
        mapValues = f: attrset: builtins.mapAttrs (_: x: f x) attrset;
        mapValuesIf = f: attrset:
          lib.filterAttrs (_: x: x != null) (mapValues f attrset);
        dirsInDir = dirname:
          lib.attrNames (lib.filterAttrs (_: type: type == "directory")
            (builtins.readDir dirname));
      in rec {
        nixosConfigurations = mapValues mkNixos hosts;

        packages = forAllUsedSystems
          (system:
            (imagePkgs system)
            // (deployerPkgs system)
          );

        apps = forAllSystems (system:
          let pkgs = pkgsFor system;
          in {
            # helper so you can do nixos-rebuild switch locally on the target machine
            nixos-rebuild = {
              type = "app";
              program = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
            };
          });
      };
  };
}
