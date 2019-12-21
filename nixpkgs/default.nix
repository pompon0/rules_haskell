let
  # 2019-11-17
  sha256 = "0r8dv6p1vhxzv50j50bjvwrq5wi9sg35nkm12ga25pw1lzvv6yr9";
  rev = "1ee040724a417d9e6e8e28dfd88a0c8c35070689";
in
import (fetchTarball {
  inherit sha256;
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
})
