{ pkgs, ... }:

{
  packages = [
    (pkgs.ruby_3_4.withPackages (gems: [ gems.minitest gems.base64 ]))
    pkgs.nodejs_24
    pkgs.gettext
  ];
}
