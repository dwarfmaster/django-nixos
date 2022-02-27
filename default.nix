{ config, lib, pkgs, ... }:

let
  django = config.services.django;
  python = import ./python.nix { inherit pkgs; };

  static-files = cfg: pkgs.runCommand
    "${cfg.name}-static"
    {}
    ''mkdir $out
      export SECRET_KEY="key" # collectstatic doesn't care about the key (with our whitenoise settings)
      export STATIC_ROOT=$out
      ${python}/bin/python ${cfg.manage} collectstatic --settings ${cfg.settings}
    '';
  load-django-env = cfg: ''
    export DJANGO_SETTINGS_MODULE=${cfg.settings}
    export ALLOWED_HOSTS=${builtins.concatStringsSep "," cfg.allowedHosts}
    export DB_NAME=${cfg.database}
    export STATIC_ROOT=${static-files cfg}
  '';
  load-django-keys = cfg: ''
    source /run/${cfg.user}/django-keys
  '';
  manage-script-content = cfg: ''
    ${load-django-env cfg}
    ${load-django-keys cfg}
    ${python}/bin/python ${cfg.manage} $@
  '';
  manage = cfg:
    pkgs.runCommand 
      "manage-${cfg.name}-script"
      {}
      ''mkdir -p $out/bin
        bin=$out/bin/manage
        echo -e '${manage-script-content cfg}' > $bin
        chmod +x $bin
      '';
  manage-via-sudo = cfg:
    pkgs.runCommand
      "manage-${cfg.name}"
      {}
      ''mkdir -p $out/bin
        bin=$out/bin/manage-${cfg.name}
        echo -e 'sudo -u ${cfg.user} bash ${manage cfg}/bin/manage $@' > $bin
        chmod +x $bin
      '';

  inherit (lib) types;
  serverType = lib.types.submodule
    ({ name, config, ...}: {
      options = {
        name = lib.mkOption {
          description = "The name of the django service";
          type = types.nonEmptyStr;
          default = name;
        };
        user = lib.mkOption {
          description = "The user to run the django service as";
          type = types.nonEmptyStr;
          default = config.name;
        };
        keysFile = lib.mkOption {
          description = "Path to a file containing secrets";
          type = types.either types.nonEmptyStr types.path;
        };
        root = lib.mkOption {
          description = "DJango source code root";
          type = types.path;
        };
        hostName = lib.mkOption {
          description = "The hostname the server is reachable on";
          type = types.str;
          default = "localhost";
        };
        setupNginx = lib.mkOption {
          description = "Whether to setup NGINX";
          type = types.bool;
          default = false;
        };
        port = lib.mkOption {
          description = "GUnicorn port to bind";
          type = types.port;
          default = 8000;
        };
        settings = lib.mkOption {
          description = "Django settings module";
          type = types.str;
        };
        manage = lib.mkOption {
          description = "Path to the manage.py of the project";
          type = types.str;
          default = "${config.root}/manage.py";
        };
        wsgi = lib.mkOption {
          description = "Django wsgi module";
          type = types.str;
          default = "${config.name}.wsgi";
        };
        processes = lib.mkOption {
          description = "Number of processes for the gunicorn server";
          type = types.int;
          default = 5;
        };
        threads = lib.mkOption {
          description = "Number of threads for gunicorn server";
          type = types.int;
          default = 5;
        };
        database = lib.mkOption {
          description = "Name of the database";
          type = types.nonEmptyStr;
          default = config.name;
        };
        allowedHosts = lib.mkOption {
          description = "List of allowed hosts";
          type = types.listOf types.str;
          default = [ config.hostName ];
        };
        nginxConfig = lib.mkOption {
          description = "NGinx configuration for this server";
          type = types.attrs;
          readOnly = true;
        };
      };

      config = {
        nginxConfig = {
          locations."/".proxyPass = "http://localhost:${toString config.port}/";
          locations."/static/".alias = "${static-files config}/";
        };
      };
    });
in
{
  options.services.django = {
    enable = lib.mkEnableOption "Management of django services";
    servers = lib.mkOption {
      description = "Django services to be managed by nixos.";
      type = types.attrsOf serverType;
      default = { };
      # TODO example
    };
  };

  config = lib.mkIf django.enable {
    # manage.py of each project can be called via manage-django-`projectname`
    environment.systemPackages =
      lib.mapAttrsToList (_: cfg: manage-via-sudo cfg) django.servers;

    # create users
    users.users =
      lib.mapAttrs'
        (_: cfg: lib.nameValuePair cfg.user { isSystemUser = true; group = cfg.user; })
        django.servers;
    users.groups =
      lib.mapAttrs'
        (_: cfg: lib.nameValuePair cfg.user { })
        django.servers;

    # The user of each server might not have permission to access the keys-file.
    # Therefore we copy the keys-file to a place where the users has access
    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList
      (_: cfg: [
        "d /run/${cfg.user} 1500 ${cfg.user} ${cfg.user} - -"
        "e /run/${cfg.user} 1500 ${cfg.user} ${cfg.user} - -"
        "C /run/${cfg.user}/django-keys 0400 ${cfg.user} ${cfg.user} - ${cfg.keysFile}"
      ])
      django.servers
    );

    systemd.services =
      (lib.mapAttrs'
        (_: cfg: let
          capabilities = if cfg.port <= 1024 then [ "CAP_NET_BIND_SERVICE" ] else [ "" ];
        in lib.nameValuePair "django-${cfg.name}" {
          description = "${cfg.name} django service";
          wantedBy = [ "multi-user.target" ];
          wants = [ "postgresql.service" ];
          after = [ "network.target" "postgresql.service" ];
          script = ''
            ${load-django-env cfg}
            ${load-django-keys cfg}
            ${python}/bin/python ${cfg.manage} migrate
            ${python}/bin/gunicorn ${cfg.wsgi} \
                --pythonpath ${cfg.root} \
                -b 0.0.0.0:${toString cfg.port} \
                --workers=${toString cfg.processes} \
                --threads=${toString cfg.threads}
          '';
          # This is inspired by the NGinx service file
          serviceConfig = {
            LimitNOFILE = "99999";
            LimitNPROC = "99999";
            User = cfg.user;
            Group = cfg.user;
            # Security
            ProtectProc = "invisible";
            ProcSubset = "pid";
            NoNewPrivileges = true;
            AmbientCapabilities = capabilities;
            CapabilityBoundingSet = capabilities;
            UMask = "066";
            # Sandboxing
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            PrivateUsers = true;
            DevicePolicy = "closed";
            ProtectHostname = true;
            ProtectClock = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
            RestrictNamespaces = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RemoveIPC = true;
            PrivateMounts = true;
            ReadWritePaths = [ "/run/${cfg.user}" ];
            ReadOnlyPaths = [ "${cfg.root}" ];
            # System Call architecture
            SystemCallArchitectures = "native";
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";
          } // (if (cfg.hostName == "localhost" && lib.all (x: x == "localhost") cfg.allowedHosts)
                then {
                  # Allow only local connection if it is to only bind localhost
                  IPAddressAllow = "localhost";
                  IPAddressDeny = "any";
                } else {});
        }) django.servers);

    services.postgresql = {
      enable = true;
      ensureDatabases = lib.mapAttrsToList (_: cfg: cfg.database) django.servers;
      ensureUsers = lib.mapAttrsToList
        (_: cfg: {
          name = cfg.user;
          ensurePermissions = {
            "DATABASE ${cfg.database}" = "ALL PRIVILEGES";
          };
        })
        django.servers;
    };

    services.nginx = {
      virtualHosts = lib.mapAttrs'
        (_: cfg: if cfg.setupNginx
                 then lib.nameValuePair cfg.hostName cfg.nginxConfig
                 else lib.nameValuePair "" null)
        django.servers;
    };
  };
}
