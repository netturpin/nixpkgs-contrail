{ contrailPkgs, pkgs_path, isContrailMaster, isContrail32 }:

with import (pkgs_path + "/nixos/lib/testing.nix") { system = builtins.currentSystem; };

let
  config = { pkgs, lib, config, ... }: {
    imports = [ ../modules/compute-node.nix ];
    config = {
      _module.args = { inherit contrailPkgs isContrailMaster isContrail32; };

      networking.firewall.enable = false;
      services.openssh.enable = true;
      services.openssh.permitRootLogin = "yes";
      users.extraUsers.root.password = "root";
      virtualisation.graphics = false;

      contrail.vrouterAgent = {
        enable = true;
        provisionning = true;
        collectorHost = "10.0.2.200";
        discoveryHost = "10.0.2.200";
        controlHost = "10.0.2.200";
        apiHost= "10.0.2.200";
      };
    };
  };
in
rec {
  computeNode = (makeTest { name = "compute-node"; machine = config; testScript = ""; }).driver;

  # This image is quiet big. There are some dependencies that should
  # be removed.
  computeNodeDockerImage = pkgs.dockerTools.buildImage {
    name = "vrouter";
    config = {
      Cmd = [ "${computeNode}/bin/nixos-run-vms" ];
      Env = [ ''
        QEMU_NET_OPTS=hostfwd=udp::51234-:51234,hostfwd=tcp::22-:22,hostfwd=tcp::8085-:8085,guestfwd=tcp:10.0.2.200:5998-tcp:discovery:5998,guestfwd=tcp:10.0.2.200:8082-tcp:api:8082''
      ];
    };
  };
}


