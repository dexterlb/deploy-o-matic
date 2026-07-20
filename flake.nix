{
  description = "Opinionated wrapper for deployment tools";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, deploy-rs }: {
    lib.deployOMatic = { templatesDir, overlaysDir ? null, overlays ? [], moduleArgs ? {}, nixpkgsConfig ? {}, ... }:
      let
        # get all templates, and from there get all hosts (≥1 hosts per template, usually 1)
        templateNames = dirsInDir templatesDir;
        hostList = builtins.concatLists (map templateHosts templateNames);
        hosts = mkHostMap hostList;
        hostsBySystem = system:
          mkHostMap (builtins.filter (host: host.system == system) hostList);

        # build a nixos configuration for the given host
        mkNixos = host: lib.nixosSystem (nixosSystemArgs host);

        # build a bootable disk image for the host, if configured
        mkImage = host:
          if host ? image then
            (mkNixos host).config.system.build.${host.image.format}
          else
            null;

        # build a deploy-rs recipe for the host, if configured
        mkDeployment = host:
          if host ? deploy then
            {
              profiles.system = {
                user = "root";
                path =
                  deploy-rs.lib.${host.system}.activate.nixos (mkNixos host);
              };
            } // host.deploy
          else
            null;

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
        templateHosts = name:
          let
            hostsFunc = import "${templatesDir}/${name}/hosts.nix";
            hostsData = hostsFunc {
              inherit nixpkgs;
            }; # maybe pass some other convenient stuff here
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

        # expose disk images as packages
        # TODO: disko now has image generation support: https://github.com/nix-community/disko/blob/master/docs/disko-images.md
        # with this, image generation can be revamped to be more flexible and to support stuff like embedding secrets
        packages = forAllUsedSystems
          (system: mapValuesIf mkImage (hostsBySystem system));

        # deploy-rs nodes
        deploy = {
          magicRollback = true;
          nodes = mapValuesIf mkDeployment hosts;
        };

        # deploy-rs checks
        checks =
          forAllSystems (system: deploy-rs.lib.${system}.deployChecks deploy);

        apps = forAllSystems (system:
          let pkgs = pkgsFor system;
          in {
            # tiny helper so you can run `nix run .#deploy -- .#hala`
            deploy = {
              type = "app";
              program = "${deploy-rs.packages.${system}.deploy-rs}/bin/deploy";
            };
            # helper so you can do nixos-rebuild switch locally on the target machine
            nixos-rebuild = {
              type = "app";
              program = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
            };
          });
      };
  };
}
