{ pkgs, ... }:
let
  python = pkgs.python38.override {
    packageOverrides = python-self: python-super: {
      gunicorn = python-super.gunicorn.overrideAttrs (oldAttrs: {
        # Necessary until https://github.com/benoitc/gunicorn/pull/2758 is
        # merged and the change makes its way in nixpkgs
        patches = [ ./0001-Prevent-unnecessary-setuid-call.patch ];
      });
    };
  };
in
python.withPackages (ps: with ps; [
  django_3
  gunicorn      # for serving via http
  psycopg2      # for connecting to postgresql
])
