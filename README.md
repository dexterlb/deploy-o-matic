## deploy-o-matic

An opinionated flake that uses [nixos-generators](https://github.com/nix-community/nixos-generators),
[deploy-rs](https://github.com/serokell/deploy-rs) and other tools to deploy nixos systems.

### Usage

The configuration is centered around defining a set of *templates*. Each template
corresponds to a different machine type, and can be instanced onto one or more *hosts*.

Deploy-o-matic expects a directory of templates, where each template is itself a directory
that contains a `default.nix` file (the main module) and a `hosts.nix` file which describes
the hosts that this template is instanced to.

Here is an example `templates/my-machine/hosts.nix`:
```nix
{ ... }: [rec {
  hostname = "foo";
  system = "x86_64-linux";
  image = {
    # settings used my nixos-generators
    format = "raw";
  };
  moduleArgs = {
    # extra arguments passed to all modules
    inherit hostname;
  };
  deploy = {
    # settings used by deploy-rs
    hostname = "${hostname}.my.domain.example.com";
    sshUser = "my-user";

    remoteBuild = false;
    fastConnection = true;
  };
}]
```

Here is an example flake that uses deploy-o-matic:

```nix
{
  description = "my flake that deploys some machines";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    deploy-o-matic.url = "github:dexterlb/deploy-o-matic";
    deploy-o-matic.inputs.nixpkgs.follows = "nixpkgs";

    # whatever other inputs my modules would need, for example home-manager
    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, deploy-o-matic, ... }@inputs:
    let
      dom = deploy-o-matic.lib.deployOMatic {
        templatesDir = ./templates;         # directory with machine template definitions
        overlaysDir = ./overlays;           # directlry with package overlays
        moduleArgs = { inherit inputs; };   # inject some arguments to be available to all modules
        nixpkgsConfig = (import ./nixpkgs-global-config.nix);
      };

      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ];
    in {
      nixosConfigurations = dom.nixosConfigurations;
      packages = dom.packages;
      deploy = dom.deploy;
      checks = dom.checks;
      apps = dom.apps;

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              OVMF.fd
              findutils
              gnumake
              nixfmt-classic
              rsync
            ];
          };
        });
    };
}
```

Then, to create an image, one would just do
```
$ nix build '.#foo'
```

Or to deploy to a remote host using deploy-rs:
```
$ nix run '.#deploy' -- '.#foo'
$ # or:
$ deploy-rs '.#foo'
```

Or to deploy the configuration of host foo while logged in locally on foo:
```
$ nixos-rebuild switch --flake '.#foo'
```
