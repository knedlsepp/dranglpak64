# Public dashboard at https://dranglpak64.knedlsepp.at via Cloudflare
# Tunnel (outbound only, works behind the phone hotspot). Credentials were
# created with `cloudflared tunnel create dranglpak64`.
{ config, ... }:
{
  age.secrets.cloudflared-dranglpak64.file = ../secrets/cloudflared-dranglpak64.json.age;
  # Account certificate from `cloudflared tunnel login`, to manage tunnels and
  # DNS routes with the cloudflared CLI on the Pi.
  age.secrets.cloudflared-cert.file = ../secrets/cloudflared-cert.pem.age;
  environment.variables.TUNNEL_ORIGIN_CERT = config.age.secrets.cloudflared-cert.path;
  services.cloudflared = {
    enable = true;
    tunnels."210907d3-ea55-4790-9e41-0d810ebcc889" = {
      credentialsFile = config.age.secrets.cloudflared-dranglpak64.path;
      ingress."dranglpak64.knedlsepp.at" = "http://localhost:80";
      default = "http_status:404";
    };
  };
}
