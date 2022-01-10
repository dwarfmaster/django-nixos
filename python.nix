{ pkgs, ... }:
let
  python = pkgs.python38;
in
python.withPackages (ps: with ps; [
  django_3
  gunicorn      # for serving via http
  psycopg2      # for connecting to postgresql
])
