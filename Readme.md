# NixOS-based WSGI deployment

Forked from https://github.com/DavHau/django-nixos

This Project aims to provide a production grade NixOS configuration for wsgi
applications. By taking your source code and some parameters as input it will
return a nixos configuration which serves your Django project.

## What you will get
- A PostgreSQL DB with access configured for django.
- A secure systemd service which serves the project via gunicorn.
- A defined way of passing secrets to the application without leaking them into
  /nix/store.
- Your static files served directly by NGinx.
- Ability to configure some common options like (allowed-hosts, port, processes,
  threads) through your nix config.
- Having your `manage.py` globally callable via `manage-projectname`. The script
  must be called with enough permissions to read the secret file.
 


## Usage

`default.nix` is a NixOS module that allows managing wsgi applications, serving
them through `gunicorn`. The flake simply exports that module as `wsgi`.

Once imported, the management of django application is done the following way:
```nix
{
  wsgi.enable = true;
  wsgi.applications = {
    project1 = { ... };
    project2 = { ... };
  };
}
```

Each server must at least define:
- `keysFile`: path to a file containing the secrets needed for the applications.
- `root`: path to the source of the application.
- `staticFiles`: path to the source of static files.
- `module`: name of the application module.

If the project is a DJango application, you must instead set `django.settings`
to the name of the django modules with the settings, and `staticFiles` and
`module` will be automatically deducted from that.

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

Each server is launch in its own systemd service named `wsgi-${projectname}`.
For security reason, by default the service is almost completely cut off from
the rest of the system, and launched with very few permissions. From some
applications that may be a problem, so every security setting in
`systemd.services.wsgi-${projectname}.serviceConfig` is set using
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


## Secrets / Keys
To pass secrets to django securely:
1. Create a file containing your secrets as environment variables.
     The syntax is the one of a systemd environment file, like this:
    ```
    SECRET_KEY="foo"
    ANOTHER_SECRET_FOR_DJANGO="bar"
    ```
2. Pass the path of the file via parameter `keys-file`.
    This file will not be managed by nix. If you are deploying to a remote host,
    make sure this file is available. There is no specific permissions required
    since the file is read directly by systemd.

