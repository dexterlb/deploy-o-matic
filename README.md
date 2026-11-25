## deploy-o-matic

Specify nixos configurations for multiple machines, and then deploy them in various ways
(generate an image, deploy over network, etc).

I tried combining tools like `nixos-generators`, `deploy-rs`, `nixos-rebuild`, etc,
but I didn't like them so I rolled my own.

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
    # settings used for image generation
    format = "raw";
  };
  moduleArgs = {
    # extra arguments passed to all modules
    inherit hostname;
  };
  deploy = {
    # settings used for remote deployment
    hostname = "${hostname}.my.domain.example.com";
    sshUser = "my-user";

    # build the system on the machine we deploy to, instead of locally
    remoteBuild = true;
    # ...or on some other machine (an ssh destination); takes precedence
    # buildHost = "my-user@builder.example.com";
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
        flake = self;                       # only needed for deploy.remoteBuild / deploy.buildHost
      };
    in {
      nixosConfigurations = dom.nixosConfigurations;
      packages = dom.packages;
      deploy = dom.deploy;
      checks = dom.checks;
      apps = dom.apps;
    };
}
```

Then, to create an image, one would just do
```
$ nix build '.#foo-image'
```

Or to deploy the configuration to a remote host:
```
$ nix run '.#foo-deploy'
```

Or use nixos-rebuild:
```
$ nixos-rebuild switch --flake '.#foo'
```

### Where the system is built

By default the deployer builds the system locally and then copies the result to
the target, which is unpleasant when the machine you deploy from is slow, is of
a different architecture, or is on the thin end of the link.

`deploy.remoteBuild = true` build on the remote host.
`deploy.buildHost = "user@some-builder"` can specify a third machine do to the build.

