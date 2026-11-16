# agenix recipients. Run agenix in this directory, e.g. to edit a secret:
#   cd secrets && nix run github:ryantm/agenix -- -e <name>.age
# After reflashing the SD card the Pi gets a new host key: update it here and
# run `nix run github:ryantm/agenix -- --rekey` (in this directory too).
let
  sepp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTL9AJG8V8Hl3yiPJeghn3GcIy3sl+jsED+RgC5Md4E";
  # /etc/ssh/ssh_host_ed25519_key.pub of the Pi
  dranglpak64 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILNUfgCwuHCgx5e5KehgwOFzOZpQBRZ+D4vEBOkAZfIg";
in
{
  # `cloudflared tunnel create dranglpak64` credentials
  "cloudflared-dranglpak64.json.age".publicKeys = [ sepp dranglpak64 ];
  # `cloudflared tunnel login` account certificate
  "cloudflared-cert.pem.age".publicKeys = [ sepp dranglpak64 ];
  # WiFi PSKs for networking.wireless.secretsFile
  "wireless.conf.age".publicKeys = [ sepp dranglpak64 ];
}
