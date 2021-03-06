{ pkgs
# I didn't find a better way to run test by using the test framework
# of the bootstrapped nixpkgs. In fact, this is to avoid the user to
# set a specific NIX_PATH env var.
, pkgs_path ? <nixpkgs>
, contrailPkgs
, isContrail32
, isContrailMaster
}:

with import (pkgs_path + /nixos/lib/testing.nix) { system = builtins.currentSystem; };
with pkgs.lib;

let
  machine = {pkgs, config, ...}:
    let
      contrailCreateNetwork = pkgs.stdenv.mkDerivation rec {
        name = "contrail-create-network";
        src = ./contrail-create-network.py;
        phases = [ "installPhase" "fixupPhase" ];
        buildInputs = [
          (pkgs.python27.withPackages (pythonPackages: with pythonPackages; [
          contrailPkgs.vnc_api contrailPkgs.cfgm_common ]))
        ];
        installPhase = ''
          mkdir -p $out/bin
          cp ${src} $out/bin/contrail-create-network.py
        '';
      };

      svcMonitor = pkgs.writeTextFile {
        name = "contrail-svc-monitor.conf";
        text = ''
          [DEFAULTS]
          rabbit_port = 5672
          rabbit_server = localhost

          log_file = /var/log/contrail/svc-monitor.log
          log_level = SYS_DEBUG
          log_local = 1

          zk_server_port = 2181
          zk_server_ip = 127.0.0.1
          cassandra_server_list = 127.0.0.1:9160
          collectors = 127.0.0.1:8086
          api_server_port = 8082
          api_server_ip = 127.0.0.1

          [SCHEDULER]
          aaa_mode = no-auth
          analytics_server_list = 127.0.0.1:8081
        '';
      };
      discovery = pkgs.writeTextFile {
        name = "contrail-discovery.conf";
        text = ''
          [DEFAULTS]
          zk_server_ip=localhost
          zk_server_port=2181
          listen_ip_addr=0.0.0.0
          listen_port=5998
          log_local=True
          log_file=/var/log/contrail/discovery.log
          log_level=SYS_DEBUG
          log_local=1
          cassandra_server_list = localhost:9160
          # minimim time to allow client to cache service information (seconds)
          ttl_min=300
          # maximum time to allow client to cache service information (seconds)
          ttl_max=1800

          # health check ping interval <=0 for disabling
          hc_interval=5

          # maximum hearbeats to miss before server will declare publisher out of
          # service.
          hc_max_miss=3

          # use short TTL for agressive rescheduling if all services are not up
          ttl_short=1

          [DNS-SERVER]
          policy=fixed
        '';
      };
      query-engine = pkgs.writeTextFile {
        name = "contrail-query-engine.conf";
        text = ''
          [DEFAULT]
          log_file = /var/log/contrail/query-engine.log
          log_level = SYS_DEBUG
          log_local = 1
          cassandra_server_list = 127.0.0.1:9042

          [DISCOVERY]
          server = 127.0.0.1
          port = 5998

          [REDIS]
          server = 127.0.0.1
          port = 6379
        '';
      };
      analytics = pkgs.writeTextFile {
        name = "contrail-analytics-api.conf";
        text = ''
          [DEFAULTS]
          cassandra_server_list = 127.0.0.1:9042
          collectors = 127.0.0.1:8086

          aaa_mode = no-auth
          partitions = 0

          log_file = /var/log/contrail/analytic-api.log
          log_level = SYS_DEBUG
          log_local = 1

          [DISCOVERY]
          disc_server_ip = 127.0.0.1
          disc_server_port = 5998

          [REDIS]
          server = 127.0.0.1
          redis_server_port = 6379
          redis_query_port = 6379
        '';
      };
      control32 = import ./configuration/R3.2/control.nix { inherit pkgs; };
      controlMaster = import ./configuration/master/control.nix { inherit pkgs; };
      control = if isContrail32 then control32 else controlMaster;

      collector32 = import ./configuration/R3.2/control.nix { inherit pkgs; };
      collectorMaster = import ./configuration/master/control.nix { inherit pkgs; };
      collector = if isContrail32 then collector32 else collectorMaster;

      api = import ./configuration/R3.2/api.nix { inherit pkgs; };
      schema = import ./configuration/R3.2/api.nix { inherit pkgs; };

    in {
      imports = [ ../modules/compute-node.nix
                  ../modules/cassandra.nix
                  ../modules/contrail-api.nix
                  ../modules/contrail-schema-transformer.nix
                  ../modules/contrail-discovery.nix ];
      config = rec {
        _module.args = { inherit contrailPkgs isContrail32 isContrailMaster; };

        services.openssh.enable = true;
        services.openssh.permitRootLogin = "yes";
        users.extraUsers.root.password = "root";

        services.rabbitmq.enable = true;
        services.zookeeper.enable = true;
        services.redis.enable = true;
        services.cassandra.enable = true;

        virtualisation = { memorySize = 4096; cores = 2; };


        environment.systemPackages = [
          contrailPkgs.tools.contrailApiCliWithExtra
          # Required by the test suite
          pkgs.jq contrailPkgs.configUtils contrailCreateNetwork
        ];

        contrail.vrouterAgent.enable = true;

        contrail.discovery = {
          enable = isContrail32;
          configFile = discovery;
        };
        contrail.api = {
          enable = true;
          configFile = api;
        };
        contrail.schemaTransformer = {
          enable = true;
          configFile = schema;
        };

        systemd.services.contrailSvcMonitor = {
          wantedBy = [ "multi-user.target" ];
          after = [ "contrailApi.service" ];
          script = "${contrailPkgs.svcMonitor}/bin/contrail-svc-monitor --conf_file ${svcMonitor}";
          path = [ pkgs.netcat ];
          postStart = ''
            sleep 2
            while ! nc -vz localhost 8088; do
              sleep 2
            done
            sleep 2
          '';
        };

        systemd.services.contrailQueryEngine = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "cassandra.service" "rabbitmq.servive" "zookeeper.service" "redis.service" ];
          preStart = "mkdir -p /var/log/contrail/";
          script = "${contrailPkgs.queryEngine}/bin/qed --conf_file ${query-engine}";
        };

        systemd.services.contrailCollector = {
          wantedBy = [ "multi-user.target" ];
          after = [ "contrailQueryEngine.service" ];
          preStart = "mkdir -p /var/log/contrail/";
          script = "${contrailPkgs.collector}/bin/contrail-collector --conf_file ${collector}";
        };

        systemd.services.contrailAnalyticsApi = {
          wantedBy = [ "multi-user.target" ];
          after = [ "contrailCollector.service" ];
          preStart = "mkdir -p /var/log/contrail/ && ${pkgs.redis}/bin/redis-cli config set protected-mode no";
          script = "${contrailPkgs.analyticsApi}/bin/contrail-analytics-api --conf_file ${analytics}";
        };

        systemd.services.contrailControl = {
          wantedBy = [ "multi-user.target" ];
          after = [ "contrailApi.service" "contrailCollector.service" ];
          preStart = "mkdir -p /var/log/contrail/";
          script = "${contrailPkgs.control}/bin/contrail-control --conf_file ${control}";
          postStart = ''
            ${contrailPkgs.configUtils}/bin/provision_control.py --api_server_ip 127.0.0.1 --api_server_port 8082   --oper add --host_name machine --host_ip 127.0.0.1 --router_asn 64512
          '';
        };

     };
  };
  testScript = let
    contrail32 =
      ''
      $machine->waitForUnit("cassandra.service");
      $machine->waitForUnit("rabbitmq.service");
      $machine->waitForUnit("zookeeper.service");
      $machine->waitForUnit("redis.service");

      $machine->waitForUnit("contrailDiscovery.service");
      $machine->waitForUnit("contrailApi.service");

      $machine->waitForUnit("contrailSvcMonitor.service");
      $machine->waitUntilSucceeds("curl localhost:8088/");

      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services[].ep_type' | grep -q IfmapServer");
      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services[].ep_type' | grep -q ApiServer");

      $machine->waitForUnit("contrailCollector.service");
      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services[].ep_type' | grep -q Collector");
      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services | map(select(.ep_type == \"Collector\")) | .[].status' | grep -q up");

      $machine->waitForUnit("contrailControl.service");
      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services[].ep_type' | grep -q xmpp-server");
      $machine->waitUntilSucceeds("curl localhost:5998/services.json | jq '.services | map(select(.ep_type == \"xmpp-server\")) | .[].status' | grep -q up");

      $machine->succeed("lsmod | grep -q vrouter");
      $machine->waitForUnit("contrailVrouterAgent.service");

      $machine->waitUntilSucceeds("curl http://localhost:8083/Snh_ShowBgpNeighborSummaryReq | grep machine | grep -q Established");

      $machine->succeed("contrail-create-network.py default-domain:default-project:vn1");
      $machine->succeed("netns-daemon-start -n default-domain:default-project:vn1 vm1");
      $machine->succeed("netns-daemon-start -n default-domain:default-project:vn1 vm2");

      $machine->succeed("ip netns exec ns-vm1 ip a | grep -q 20.1.1.252");
      $machine->succeed("ip netns exec ns-vm1 ping -c1 20.1.1.251");

      $machine->waitForUnit("contrailAnalyticsApi.service");
      $machine->waitUntilSucceeds("curl http://localhost:8081/analytics/uves/vrouters | jq '. | length' | grep -q 1");
      '';
    contrailMaster =
     ''
      $machine->waitForUnit("cassandra.service");
      $machine->waitForUnit("rabbitmq.service");
      $machine->waitForUnit("zookeeper.service");
      $machine->waitForUnit("redis.service");

      $machine->waitForUnit("contrailApi.service");

      $machine->waitForUnit("contrailSvcMonitor.service");
      $machine->waitUntilSucceeds("curl localhost:8088/");

      $machine->waitForUnit("contrailCollector.service");
      $machine->waitForUnit("contrailControl.service");
      $machine->succeed("lsmod | grep -q vrouter");
      $machine->waitForUnit("contrailVrouterAgent.service");

      $machine->waitUntilSucceeds("curl http://localhost:8083/Snh_ShowBgpNeighborSummaryReq | grep machine | grep -q Established");

      $machine->succeed("contrail-create-network.py default-domain:default-project:vn1");
      $machine->succeed("netns-daemon-start -n default-domain:default-project:vn1 vm1");
      $machine->succeed("netns-daemon-start -n default-domain:default-project:vn1 vm2");

      # $machine->succeed("ip netns exec ns-vm1 ip a | grep -q 20.1.1.252");
      # $machine->succeed("ip netns exec ns-vm1 ping -c1 20.1.1.251");
      '';
    in if isContrail32 then contrail32 else contrailMaster;
in
  makeTest { name = "all-in-one"; nodes = { inherit machine; }; testScript = testScript; }
