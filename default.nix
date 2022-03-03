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
  django-environment = cfg: {
    DJANGO_SETTINGS_MODULE = "${cfg.django.settings}";
    ALLOWED_HOSTS = if cfg.allowedHosts == []
                    then "localhost"
                    else "${builtins.concatStringsSep "," cfg.allowedHosts}";
    DB_NAME = "${cfg.database}";
    STATIC_ROOT = "${static-files cfg}";
  };
  make-export = env:
    builtins.concatStringsSep "\n" (lib.mapAttrsToList (name: val: "export ${name}=\"${val}\"") env);
  load-django-env = cfg: make-export (django-environment cfg);
  load-django-keys = cfg: ''
    set -a
    source ${cfg.keysFile}
    set +a
  '';
  manage-script-content = cfg: ''
    ${python}/bin/python ${cfg.django.manage} $@
  '';
  manage = cfg: pkgs.writeScript "manage-${cfg.name}-script" (manage-script-content cfg);
  manage-via-sudo = cfg:
    pkgs.writeScriptBin "manage-${cfg.name}" ''
        ${load-django-env cfg}
        ${load-django-keys cfg}
        sudo -E -u ${cfg.user} ${manage cfg} $@
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
          description = "Path to a file containing secrets as a systemd environment file";
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
          default = [ config.hostName ];
        };
        unixSocket = {
          path = lib.mkOption {
            description = "Path to unix socket to bind. If set ignores port and only bind this socket.";
            type = types.nullOr types.str;
            default = null;
          };
          user = lib.mkOption {
            description = "User that should own the unix socket.";
            type = types.str;
            default = config.services.nginx.user;
          };
          group = lib.mkOption {
            description = "Group that should own the unix socket.";
            type = types.str;
            default = config.services.nginx.group;
          };
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
        binding = lib.mkOption {
          description = "The url of the bound socket, either unix:unixSocket.path or 0.0.0.0:port";
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

        # Security options
        security = {
          noNetwork = lib.mkOption {
            description = "Isolate the application from the network";
            type = types.bool;
            default = false;
          };
        };
      };

      config = lib.mkMerge [
        {
          # Config inspired by https://docs.gunicorn.org/en/latest/deploy.html
          # Check for static file, if not fuound proxy to app
          upstreamName = "${config.name}-upstream";
          binding = if builtins.isNull config.unixSocket.path
                    then "0.0.0.0:${toString config.port}"
                    else "unix:${config.unixSocket.path}";
          nginxHostConfig = {
            root = "${config.staticFiles}";
            locations."/".tryFiles = "$uri @proxy_to_app";
            locations."@proxy_to_app" = {
              proxyPass = "http://${config.upstreamName}";
              extraConfig = ''
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_redirect off;
                client_max_body_size 4G;
              '';
            };
          };
          nginxUpstreamConfig = {
            servers."${config.binding}" = { };
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
    # manage.py of each django application can be called via manage-`projectname`
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

    systemd.services =
      (lib.mapAttrs'
        (_: cfg: let
          capabilities = if cfg.port <= 1024 then [ "CAP_NET_BIND_SERVICE" ] else [ "" ];
        in lib.nameValuePair "wsgi-${cfg.name}" {
          description = "${cfg.name} wsgi application";
          wants = [ "postgresql.service" ];
          after = [ "network.target" "postgresql.service" ];
          environment = if builtins.isNull cfg.django.settings then {} else django-environment cfg;
          serviceConfig = {
            ExecStart = ''
                ${python}/bin/gunicorn ${cfg.module} \
                    --pythonpath ${cfg.root} \
                    --workers=${toString cfg.processes} \
                    --threads=${toString cfg.threads}
              '';
            LimitNOFILE = "99999";
            LimitNPROC = "99999";
            EnvironmentFile = "${cfg.keysFile}";
            User = cfg.user;
            Group = cfg.user;
            # The following is inspired by the NGinx service file
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
            RestrictNamespaces = lib.mkDefault true;
            LockPersonality = lib.mkDefault true;
            MemoryDenyWriteExecute = lib.mkDefault true;
            RestrictRealtime = lib.mkDefault true;
            RestrictSUIDSGID = lib.mkDefault true;
            RemoveIPC = lib.mkDefault true;
            PrivateMounts = lib.mkDefault true;
            ReadOnlyPaths = lib.mkDefault [ "${cfg.root}" ];
            # System Call architecture
            SystemCallArchitectures = lib.mkDefault "native";
            SystemCallFilter = lib.mkDefault [ "@system-service" "~@resources" ];
            SystemCallErrorNumber = lib.mkDefault "EPERM";
          }
          // (if builtins.isNull cfg.unixSocket && cfg.security.noNetwork
              then {
                # Allow only local connection if it is to only bind localhost
                IPAddressAllow = lib.mkDefault "localhost";
                IPAddressDeny = lib.mkDefault "any";
                RestrictAddressFamilies = lib.mkDefault [ "AF_UNIX" "AF_INET" "AF_INET6" ];
              } else (if cfg.security.noNetwork
                then {
                  # Prevents any networking
                  IPAddressDeny = lib.mkDefault "any";
                  RestrictAddressFamilies = lib.mkDefault [ "AF_UNIX" ];
                  PrivateNetwork = lib.mkDefault true;
                } else {
                  RestrictAddressFamilies = lib.mkDefault [ "AF_UNIX" "AF_INET" "AF_INET6" ];
                }))
          // (if builtins.isNull cfg.django.settings then {}
              else {
                ExecStartPre = ''
                    ${python}/bin/python ${cfg.django.manage} migrate
                  '';
              });
        }) cfg.applications);
    systemd.sockets =
      (lib.mapAttrs'
        (_: cfg: let
        in lib.nameValuePair "wsgi-${cfg.name}" {
          listenStreams = if builtins.isNull cfg.unixSocket.path
                          then [ "0.0.0.0:${toString cfg.port}" ]
                          else [ "${cfg.unixSocket.path}" ];
          wantedBy = [ "multi-user.target" ];
          socketConfig = {
            SocketUser = config.services.nginx.user;
            SocketGroup = config.services.nginx.group;
            SocketMode = "0600";
          };
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
