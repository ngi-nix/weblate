{ config, lib, pkgs, ... }:

let
  cfg = config.services.weblate;

  # This extends and overrides the weblate/settings_example.py code found in upstream.
  weblateConfig = ''

    # This was autogenerated by the NixOS module.

    SITE_TITLE = "Weblate"
    SITE_DOMAIN = "${cfg.localDomain}"
    # TLS terminates at the reverse proxy, but this setting controls how links to weblate are generated.
    ENABLE_HTTPS = True
    # TODO disable this, shouldn't be enabled in production
    DEBUG = True
    DATA_DIR = "/var/lib/weblate"
    STATIC_ROOT = "${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/static/"
    MEDIA_ROOT = "/var/lib/weblate/media"

    DATABASES = {
      "default": {
        "ENGINE": "django.db.backends.postgresql",
        "HOST": "/run/postgresql",
        "NAME": "weblate",
        "USER": "weblate",
        "PASSWORD": "",
        "PORT": ""
      }
    }

    with open("${cfg.djangoSecretKeyFile}") as f:
      SECRET_KEY = f.read().rstrip("\n")

    CACHES = {
      "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": "unix://${config.services.redis.unixSocket}",
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
            "PARSER_CLASS": "redis.connection.HiredisParser",
            "PASSWORD": None,
            "CONNECTION_POOL_KWARGS": {},
        },
        "KEY_PREFIX": "weblate",
      },
      "avatar": {
        "BACKEND": "django.core.cache.backends.filebased.FileBasedCache",
        "LOCATION": "/var/lib/weblate/avatar-cache",
        "TIMEOUT": 86400,
        "OPTIONS": {"MAX_ENTRIES": 1000},
      }
    }

    ADMINS = (("Weblate Admin", "${cfg.smtp.user}"),)

    EMAIL_HOST = "127.0.0.1"
    EMAIL_USE_TLS = True
    EMAIL_HOST_USER = "${cfg.smtp.user}"
    SERVER_EMAIL = "${cfg.smtp.user}"
    DEFAULT_FROM_EMAIL = "${cfg.smtp.user}"
    EMAIL_PORT = 587
    with open("${cfg.smtp.passwordFile}") as f:
      EMAIL_HOST_PASSWORD = f.read().rstrip("\n")

    CELERY_TASK_ALWAYS_EAGER = False
    CELERY_BROKER_URL = "redis+socket:://${config.services.redis.unixSocket}"
    CELERY_RESULT_BACKEND = CELERY_BROKER_URL

    ${cfg.extraConfig}
  '';
  settings_py = pkgs.runCommand "weblate_settings.py" { } ''
    mkdir -p $out
    cat ${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/settings_example.py > $out/settings.py
    cat >> $out/settings.py <<EOF${weblateConfig}EOF
  '';
  uwsgiConfig.uwsgi = {
    type = "normal";
    plugins = [ "python3" ];
    master = true;
    socket = "/run/weblate.socket";
    die-on-idle = true;
    die-on-term = true;
    idle = 600;
    manage-script-name = true;
    cheap = true;
    chmod-socket = "770";
    chown-socket = "weblate:weblate";
    uid = "weblate";
    gid = "weblate";
    wsgi-file = "${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/wsgi.py";
    pyhome = pkgs.weblate;

    # Some more recommendations by upstream:
    # https://docs.weblate.org/en/latest/admin/install.html#sample-configuration-for-nginx-and-uwsgi
    buffer-size = 8192;
    reload-on-rss = 250;
    workers = 8;
    enable-threads = true;
    close-on-exec = true;
    umask = "0022";
    ignore-sigpipe = true;
    ignore-write-errors = true;
    disable-write-exception = true;
  };
  environment = {
    PYTHONPATH = "${settings_py}";
    DJANGO_SETTINGS_MODULE = "settings";
    GI_TYPELIB_PATH = "${pkgs.pango.out}/lib/girepository-1.0:${pkgs.harfbuzz}/lib/girepository-1.0";
  };
in
{

  options = {
    services.weblate = {
      enable = lib.mkEnableOption "Weblate service";

      localDomain = lib.mkOption {
        description = "The domain serving your Weblate instance.";
        example = "weblate.example.org";
        type = lib.types.str;
      };

      djangoSecretKeyFile = lib.mkOption {
        description = ''
          Location of the Django secret key.

          This should be a string, not a nix path, since nix paths are copied into the world-readable nix store.
        '';
        type = lib.types.path;
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          Text to append to <filename>settings.py</filename> Weblate config file.
        '';
      };

      smtp = {
        user = lib.mkOption {
          description = "SMTP login name.";
          example = "weblate@weblate.example.org";
          type = lib.types.str;
        };

        createLocally = lib.mkOption {
          description = "Configure local Postfix SMTP server for Weblate.";
          type = lib.types.bool;
          default = true;
        };
        passwordFile = lib.mkOption {
          description = ''
            Location of a file containing the SMTP password.

            This should be a string, not a nix path, since nix paths are copied into the world-readable nix store.
          '';
          type = lib.types.path;
        };
      };

    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [ ];

    services.nginx = {
      enable = true;
      virtualHosts."${cfg.localDomain}" = {

        forceSSL = true;
        enableACME = true;

        locations = {
          "= /favicon.ico".alias = "${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/static/favicon.ico";
          "/static/".alias = "${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/static/";
          "/media/".alias = "/var/lib/weblate/media/";
          "/".extraConfig = ''
            # Needed for long running operations in admin interface
            uwsgi_read_timeout 3600;
            # Adjust based to uwsgi configuration:
            uwsgi_pass unix:///run/weblate.socket;
            # uwsgi_pass 127.0.0.1:8080;
          '';
        };

      };
    };

    systemd.services.weblate-postgresql-setup = {
      description = "Weblate PostgreSQL setup";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = ''
          ${pkgs.postgresql}/bin/psql weblate -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"
        '';
      };
    };

    systemd.services.weblate-migrate = {
      description = "Weblate migration";
      wantedBy = [
        "weblate.service"
        "multi-user.target"
      ];
      after = [
        "postgresql.service"
        "weblate-postgresql-setup.service"
      ];
      inherit environment;
      path = with pkgs; [ gitSVN ];
      serviceConfig = {
        Type = "oneshot";
        # WorkingDirectory = pkgs.weblate;
        StateDirectory = "weblate";
        User = "weblate";
        Group = "weblate";
        ExecStart = "${pkgs.weblate}/bin/weblate migrate --noinput";
      };
    };

    systemd.services.weblate-celery = {
      description = "Weblate Celery";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "redis.service"
        "postgresql.service"
      ];
      environment = environment // {
        CELERY_WORKER_RUNNING = "1";
      };
      # Recommendations from:
      # https://github.com/WeblateOrg/weblate/blob/main/weblate/examples/celery-weblate.service
      serviceConfig =
        let
          # We have to push %n through systemd's replacement, therefore %%n.
          pidFile = "/run/weblate/%%n.pid";
          nodes = "celery notify memory backup translate";
          cmd = verb: ''
            ${pkgs.weblate}/bin/celery multi ${verb} \
              ${nodes} \
              -A "weblate.utils" \
              --pidfile=${pidFile} \
              --logfile=/var/log/celery/%%n%%I.log \
              --loglevel=DEBUG \
              --beat:celery \
              --queues:celery=celery \
              --prefetch-multiplier:celery=4 \
              --queues:notify=notify \
              --prefetch-multiplier:notify=10 \
              --queues:memory=memory \
              --prefetch-multiplier:memory=10 \
              --queues:translate=translate \
              --prefetch-multiplier:translate=4 \
              --concurrency:backup=1 \
              --queues:backup=backup \
              --prefetch-multiplier:backup=2
          '';
        in
        {
          Type = "forking";
          User = "weblate";
          Group = "weblate";
          WorkingDirectory = "${pkgs.weblate}/lib/${pkgs.python3.libPrefix}/site-packages/weblate/";
          RuntimeDirectory = "weblate";
          RuntimeDirectoryPreserve = "restart";
          LogsDirectory = "celery";
          ExecStart = cmd "start";
          ExecReload = cmd "restart";
          ExecStop = ''
            ${pkgs.weblate}/bin/celery multi stopwait \
              ${nodes} \
              --pidfile=${pidFile}
          '';
          Restart = "always";
        };
    };

    systemd.services.weblate = {
      description = "Weblate uWSGI app";
      after = [
        "network.target"
        "postgresql.service"
        "redis.service"
        "weblate-migrate.service"
        "weblate-postgresql-setup.service"
      ];
      requires = [
        "weblate-migrate.service"
        "weblate-postgresql-setup.service"
        "weblate-celery.service"
        "weblate.socket"
      ];
      inherit environment;
      path = with pkgs; [
        gitSVN

        #optional
        git-review
        tesseract
        licensee
      ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart =
          let
            uwsgi = pkgs.uwsgi.override { plugins = [ "python3" ]; };
            jsonConfig = pkgs.writeText "uwsgi.json" (builtins.toJSON uwsgiConfig);
          in
          "${uwsgi}/bin/uwsgi --json ${jsonConfig}";
        Restart = "on-failure";
        KillSignal = "SIGTERM";
        WorkingDirectory = pkgs.weblate;
        StateDirectory = "weblate";
        RuntimeDirectory = "weblate";
        User = "weblate";
        Group = "weblate";
      };
    };

    systemd.sockets.weblate = {
      before = [ "nginx.service" ];
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/weblate.socket";
        SocketUser = "weblate";
        SocketGroup = "weblate";
        SocketMode = "770";
      };
    };

    services.postfix = lib.mkIf cfg.smtp.createLocally {
      enable = true;
    };

    services.redis = {
      enable = true;
      unixSocket = "/run/redis/redis.sock";
      unixSocketPerm = 770;
    };

    services.postgresql = {
      enable = true;
      ensureUsers = [
        {
          name = "weblate";
          ensurePermissions."DATABASE weblate" = "ALL PRIVILEGES";
        }
      ];
      ensureDatabases = [ "weblate" ];
    };

    users.users.weblate = {
      isSystemUser = true;
      group = "weblate";
      extraGroups = [
        "redis"
      ];
      packages = [ pkgs.weblate ];
    };

    users.groups.weblate.members = [ config.services.nginx.user ];
  };

  meta.maintainers = with lib.maintainers; [ erictapen ];

}


