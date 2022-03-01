{ config, lib, pkgs, ... }:

let
  cfg = config.services.wsgi;
  python = import ./python.nix { inherit pkgs; };

  static-files = cfg: pkgs.runCommand
    "${cfg.name}-static" {} ''
      mkdir -p $out/static
      export SECRET_KEY="no-secret" # Secret keys must be set bust is not used for collectstatic
      export STATIC_ROOT=$out/static
      ${python}/bin/python ${cfg.django.manage} collectstatic --settings ${cfg.django.settings}
    '';
  load-django-env = cfg: ''
    export DJANGO_SETTINGS_MODULE=${cfg.django.settings}
    export ALLOWED_HOSTS=${builtins.concatStringsSep "," cfg.allowedHosts}
    export DB_NAME=${cfg.database}
    export STATIC_ROOT=${static-files cfg}
  '';
  load-django-keys = cfg: ''
    source /run/${cfg.user}/wsgi-secrets
  '';
  manage-script-content = cfg: ''
    ${load-django-env cfg}
    ${load-django-keys cfg}
    ${python}/bin/python ${cfg.django.manage} $@
  '';
  manage = cfg: pkgs.writeScript "manage-${cfg.name}" (manage-script-content cfg);
  manage-via-sudo = cfg:
    pkgs.writeScriptBin "manage-django-${cfg.name}" ''
        sudo -u ${cfg.user} bash ${manage cfg} $@
    '';

  inherit (lib) types;
  applicationType = lib.types.submodule
    ({ name, config, ...}: {
      options = {
        name = lib.mkOption {
          description = "The name of the wsgi application";
          type = types.nonEmptyStr;
          default = name;
        };
        user = lib.mkOption {
          description = "The user to run the wsgi service as";
          type = types.nonEmptyStr;
          default = config.name;
        };
        keysFile = lib.mkOption {
          description = "Path to a file containing secrets";
          type = types.either types.nonEmptyStr types.path;
        };
        root = lib.mkOption {
          description = "wsgi application source root";
          type = types.path;
        };
        staticFiles = lib.mkOption {
          description = "Static files to serve";
          type = types.either types.path types.str;
        };
        module = lib.mkOption {
          description = "Application module in the source";
          type = types.str;
        };
        hostName = lib.mkOption {
          description = "The hostname the server is reachable on";
          type = types.str;
        };
        setupNginx = lib.mkOption {
          description = "Whether to setup NGINX";
          type = types.bool;
          default = false;
        };
        port = lib.mkOption {
          description = "Local port to bind";
          type = types.port;
          default = 8000;
        };
        processes = lib.mkOption {
          description = "Number of processes for the server";
          type = types.int;
          default = 5;
        };
        threads = lib.mkOption {
          description = "Number of threads for the server";
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
          default = [ "localhost" ];
        };

        # Read-only
        nginxHostConfig = lib.mkOption {
          description = "NGinx configuration for this server";
          type = types.attrs;
          readOnly = true;
        };
        upstreamName = lib.mkOption {
          description = "Name of the nginx upstream entry";
          type = types.str;
          readOnly = true;
        };
        nginxUpstreamConfig = lib.mkOption {
          description = "NGinx upstream server";
          type = types.attrs;
          readOnly = true;
        };

        # Django specific
        django = {
          settings = lib.mkOption {
            description = "Django settings module, if set the application is assumed to be based on DJango";
            type = types.nullOr types.str;
            default = null;
          };
          manage = lib.mkOption {
            description = "Path to the manage.py of the project";
            type = types.str;
            default = "${config.root}/manage.py";
          };
        };
      };

      config = lib.mkMerge [
        {
          # Config inspired by https://docs.gunicorn.org/en/latest/deploy.html
          # Check for static file, if not fuound proxy to app
          upstreamName = "${config.name}-upstream";
          nginxHostConfig = {
            root = "${config.staticFiles}";
            locations."/".tryFiles = "$uri @proxy_to_app";
            locations."@proxy_to_app" = {
              proxyPass = "http://${config.upstreamName}";
              extraConfig = ''
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header Host $host;
                proxy_redirect off;
                client_max_body_size 4G;
              '';
            };
          };
          nginxUpstreamConfig = {
            servers."0.0.0.0:${toString config.port}" = { };
          };
        }
        (lib.mkIf (!(builtins.isNull config.django.settings)) {
          staticFiles = "${static-files config}";
          module = "${config.name}.wsgi";
        })
      ];
    });
in
{
  options.services.wsgi = {
    enable = lib.mkEnableOption "Management of wsgi applications";
    applications = lib.mkOption {
      description = "wsgi applications to be managed by nixos.";
      type = types.attrsOf applicationType;
      default = { };
      # TODO example
    };
  };

  config = lib.mkIf cfg.enable {
    # manage.py of each django application can be called via manage-django-`projectname`
    environment.systemPackages =
      lib.mapAttrsToList (_: cfg: manage-via-sudo cfg)
        (lib.filterAttrs (_: cfg: !(builtins.isNull cfg.django.settings)) cfg.applications);

    # create users
    users.users =
      lib.mapAttrs'
        (_: cfg: lib.nameValuePair cfg.user { isSystemUser = true; group = cfg.user; })
        cfg.applications;
    users.groups =
      lib.mapAttrs'
        (_: cfg: lib.nameValuePair cfg.user { })
        cfg.applications;

    # The user of each server might not have permission to access the keys-file.
    # Therefore we copy the keys-file to a place where the users has access
    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList
      (_: cfg: [
        "d /run/${cfg.user} 1500 ${cfg.user} ${cfg.user} - -"
        "e /run/${cfg.user} 1500 ${cfg.user} ${cfg.user} - -"
        "C /run/${cfg.user}/wsgi-secrets 0400 ${cfg.user} ${cfg.user} - ${cfg.keysFile}"
      ])
      cfg.applications
    );

    systemd.services =
      (lib.mapAttrs'
        (_: cfg: let
          capabilities = if cfg.port <= 1024 then [ "CAP_NET_BIND_SERVICE" ] else [ "" ];
        in lib.nameValuePair "wsgi-${cfg.name}" {
          description = "${cfg.name} wsgi application";
          wantedBy = [ "multi-user.target" ];
          wants = [ "postgresql.service" ];
          after = [ "network.target" "postgresql.service" ];
          script = (if builtins.isNull cfg.django.settings then "" else ''
            ${load-django-env cfg}
            ${load-django-keys cfg}
          '') + ''
            ${python}/bin/python ${cfg.django.manage} migrate
            ${python}/bin/gunicorn ${cfg.module} \
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
            ProtectProc = lib.mkDefault "invisible";
            ProcSubset = lib.mkDefault "pid";
            NoNewPrivileges = lib.mkDefault true;
            AmbientCapabilities = lib.mkDefault capabilities;
            CapabilityBoundingSet = lib.mkDefault capabilities;
            UMask = lib.mkDefault "066";
            # Sandboxing
            ProtectSystem = lib.mkDefault "strict";
            ProtectHome = lib.mkDefault true;
            PrivateTmp = lib.mkDefault true;
            PrivateDevices = lib.mkDefault true;
            PrivateUsers = lib.mkDefault true;
            DevicePolicy = lib.mkDefault "closed";
            ProtectHostname = lib.mkDefault true;
            ProtectClock = lib.mkDefault true;
            ProtectKernelTunables = lib.mkDefault true;
            ProtectKernelModules = lib.mkDefault true;
            ProtectKernelLogs = lib.mkDefault true;
            ProtectControlGroups = lib.mkDefault true;
            RestrictAddressFamilies = lib.mkDefault [ "AF_UNIX" "AF_INET" "AF_INET6" ];
            RestrictNamespaces = lib.mkDefault true;
            LockPersonality = lib.mkDefault true;
            MemoryDenyWriteExecute = lib.mkDefault true;
            RestrictRealtime = lib.mkDefault true;
            RestrictSUIDSGID = lib.mkDefault true;
            RemoveIPC = lib.mkDefault true;
            PrivateMounts = lib.mkDefault true;
            ReadWritePaths = lib.mkDefault [ "/run/${cfg.user}" ];
            ReadOnlyPaths = lib.mkDefault [ "${cfg.root}" ];
            # System Call architecture
            SystemCallArchitectures = lib.mkDefault "native";
            SystemCallFilter = lib.mkDefault [ "@system-service" "~@resources" ];
            SystemCallErrorNumber = lib.mkDefault "EPERM";
          } // (if (lib.all (x: x == "localhost") cfg.allowedHosts)
                then {
                  # Allow only local connection if it is to only bind localhost
                  IPAddressAllow = lib.mkDefault "localhost";
                  IPAddressDeny = lib.mkDefault "any";
                } else {});
        }) cfg.applications);

    services.postgresql = {
      enable = true;
      ensureDatabases = lib.mapAttrsToList (_: cfg: cfg.database) cfg.applications;
      ensureUsers = lib.mapAttrsToList
        (_: cfg: {
          name = cfg.user;
          ensurePermissions = {
            "DATABASE ${cfg.database}" = "ALL PRIVILEGES";
          };
        })
        cfg.applications;
    };

    services.nginx = {
      virtualHosts = lib.mapAttrs'
        (_: cfg: if cfg.setupNginx
                 then lib.nameValuePair cfg.hostName cfg.nginxHostConfig
                 else lib.nameValuePair "" null)
        cfg.applications;
      upstreams = lib.mapAttrs'
        (_: cfg: if cfg.setupNginx
                 then lib.nameValuePair cfg.upstreamName cfg.nginxUpstreamConfig
                 else lib.nameValuePair "" null)
        cfg.applications;
    };
  };
}
