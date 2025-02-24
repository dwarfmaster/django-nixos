# NixOS-based Django deployment

Forked from https://github.com/DavHau/django-nixos

This Project aims to provide a production grade NixOS configuration for Django
projects. By taking your source code and some parameters as input it will return
a nixos configuration which serves your Django project.

## What you will get
- A PostgreSQL DB with access configured for django
- A systemd service which serves the project via gunicorn
- A defined way of passing secrets to Django without leaking them into
  /nix/store
- Your static files as a separated build artifact (by default served via
  whitenoise)
- Ability to configure some common options like (allowed-hosts, port, processes,
  threads) through your nix config.
- Having your `manage.py` globally callable via `manage-projectname` (only via
  root/sudo)


## Usage

`default.nix` is a NixOS module that allows managing django applications,
serving them through `gunicorn`. The flake simply exports that module as django.

Once imported, the management of django application is done the following way:
```nix
{
  django.enable = true;
  django.servers = {
    project1 = { ... };
    project2 = { ... };
  }
}
```

Each server must at least define:
- `keysFile`: path to a file containing the secrets needed for the applications.
- `root`: path to the source of the application.
- `settings`: name of the django module with the settings.

Some additional interesting options can be set:
- `hostName`: the hostname the server is reachable on. Default to `localhost`.
- `allowedHosts`: a list of hosts allowed to connect. If it only contains
  `localhost`, the application is launched with a network trafic jail that
  prevents it to communicate outside. To change that, set
  `systemd.services.django-${projectname}.serviceConfig.IPAddressDeny` to `""`.
- `port`: the local port to bind
- `setupNginx`: automatically setup Nginx for `hostName`. Default to `false`.

The list of all options can be read directly from `default.nix`.

## Security

Each server is launch in its own systemd service named `django-${projectname}`.
For security reason, by default the service is almost completely cut off from
the rest of the system, and launched with very few permissions. From some
applications that may be a problem, so every security setting in
`systemd.services.django-${projectname}.serviceConfig` is set using
`lib.mkDefault`.

TODO improved settings:
- Support using unix sockets and remove `AF_INET` and `AF_INET6` from the
  address families.
- Consider setting up `PrivateNetwork=true` with a bridge to the main network
  for additional isolation, and maybe no bridge if it only communicates through
  unix sockets. Maybe make that opt-in with an option.
- Fix `gunicorn` to be able to add `~@privileged` to the system call filter.

## Prerequisites
Django settings must be configured to:
 - load `SECRET_KEY` and `STATIC_ROOT` from the environment:
    ```python
    SECRET_KEY=environ.get('SECRET_KEY')
    STATIC_ROOT=environ.get('STATIC_ROOT')
    ```
 - load `ALLOWED_HOSTS` from a comma separated list environment variable:
    ```python
    ALLOWED_HOSTS = list(environ.get('ALLOWED_HOSTS', default='').split(','))
    ```
 - use exactly this `DATABASES` configuration:
    ```python
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': environ.get('DB_NAME'),
            'HOST': '',
        }
    }
    ```

To serve static files out of the box, include the whitenoise middleware:
```python
MIDDLEWARE += [ 'whitenoise.middleware.WhiteNoiseMiddleware' ]
STATICFILES_STORAGE = 'whitenoise.storage.CompressedStaticFilesStorage'
```

(See `./examples/djangoproject/djangoproject/settings_nix.py` for full example)


## Secrets / Keys
To pass secrets to django securely:
1. Create a file containing your secrets as environment variables like this:
    ```
    export SECRET_KEY="foo"
    export ANOTHER_SECRET_FOR_DJANGO="bar"
    ```
2. Pass the path of the file via parameter `keys-file`  
    This file will not be managed by nix.
    If you are deploying to a remote host, make sure this file is available. An example on how to do this with NixOps can be found under `./examples/nixops`

A systemd service running as root will later pick up that file and copy it to a
destination under `/run/` where only the django system user can read it. Make
sure by yourself to protect the source file you uploaded to the remote host
with proper permissions or use the provided NixOps example.

## Examples
See `Readme.md` inside `./examples`
