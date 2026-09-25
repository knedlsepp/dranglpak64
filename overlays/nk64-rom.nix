{ nk64, ... }@inputs:
self: super:
{
  # nk64's prebuilt IDO compiler tools are x86-64 only, so the ROM has to be
  # built for x86_64-linux even though dranglpak64 is aarch64-linux.
  # nixos-rebuild --target-host builds it on the deploy machine and ships it
  # to the Pi as part of the system closure.
  nk64-rom = inputs.nk64.packages.x86_64-linux.default;
}
