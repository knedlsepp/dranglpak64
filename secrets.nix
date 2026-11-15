# agenix recipients. Edit a secret with `nix run github:ryantm/agenix -- -e secrets/<name>.age`.
# After reflashing the SD card the Pi gets a new host key: update it here and
# run `nix run github:ryantm/agenix -- --rekey`.
let
  sepp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTL9AJG8V8Hl3yiPJeghn3GcIy3sl+jsED+RgC5Md4E";
  # /etc/ssh/ssh_host_ed25519_key.pub of the Pi
  dranglpak64 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILNUfgCwuHCgx5e5KehgwOFzOZpQBRZ+D4vEBOkAZfIg";
in
{
  # WiFi PSKs for networking.wireless.secretsFile
  "secrets/wireless.conf.age".publicKeys = [ sepp dranglpak64 ];
}
