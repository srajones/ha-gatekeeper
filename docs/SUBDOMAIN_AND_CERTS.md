# Putting Gatekeeper on its own subdomain (nginx + Let's Encrypt you already run)

This is for a server that **already** runs nginx with certbot (or acme.sh) for other sites. The installer's option 3
("private, behind my own web server") leaves Gatekeeper listening on `127.0.0.1:8080` only; nginx is the front door.

**Nothing here is automatic.** The installer never reads, edits or reloads your nginx or your certificates, and neither
helper command below changes anything either. You run every command yourself and see it first.

```text
sudo gatekeeper proxy-help [name]    a long step-by-step guide for your server, with the exact commands
sudo gatekeeper proxy-check [name]   tests the finished setup from every angle and says what to fix
```

Run them with `sudo` so they can read nginx's configuration and `.env`. Both are safe to run as often as you like.

## What `proxy-help` does

1. **Looks** (read-only): is nginx there and which version, how site files are organised (`sites-enabled` or
   `conf.d`), whether certbot/acme.sh exist, whether renewal is automatic, whether a certificate already covers the new
   name (including wildcards), whether nginx already has a server block for it.
2. **Suggests a safety copy** of `/etc/nginx` and `/etc/letsencrypt` (root-only, one command).
3. **DNS**: the exact record to create, the server's IP, and whether the name already points at this server. Notes for
   Cloudflare (use the grey cloud until the certificate is issued) and stray IPv6 records.
4. **Ports** 80/443: how to check ufw and your hosting provider's firewall.
5. **Certificate**: only for the new name, never touching existing ones. It prints a port-80-only nginx file first (so
   Let's Encrypt can prove ownership), then the commands: a `--dry-run` rehearsal, then the real
   `certbot certonly ...`. `certonly` fetches a certificate and edits no nginx file. If a wildcard certificate already
   covers the name, this step is skipped.
6. **The finished site file** (HTTP redirects to HTTPS, HTTPS forwards to Gatekeeper). It adds no `http2`,
   `default_server` or `ipv6only` options, so it cannot change how your other sites listen. IPv6 `listen` lines appear
   only if your nginx already uses IPv6.
7. **Gatekeeper's own settings** (public address, one trusted proxy) and **how to test and undo**.

The two ready-to-copy files are written to `<install dir>/proxy/` (inside Gatekeeper's own folder) so you can
`sudo cp` them. That folder is the only place the command writes.

## Why your existing setup stays safe

- It never runs `certbot` at all (not even `certbot plugins`, which writes logs and takes locks). The nginx plugin is
  detected by looking at files.
- It runs only read-only commands: `nginx -v`, `nginx -T` (prints the configuration), `systemctl is-active/is-enabled`,
  `ufw status`, `dpkg-query -W`, DNS lookups, TLS handshakes and HTTP requests to your own names.
- The step-by-step commands you run use `nginx -t` **before** every reload and tell you to stop if it does not say
  `syntax is ok` and `test is successful`. A reload keeps all existing connections and sites up.
- A test suite (`deploy/tests/proxy.test.sh`) replaces nginx, certbot, systemctl, ufw and docker with stubs that log
  every call. It fails if any call is not on the read-only list, if the fake `/etc/nginx` or `/etc/letsencrypt` trees
  change by even one byte, and if the script source contains a mutating command or a write outside its own folder.
- The generated files were also checked with a real nginx 1.24 (Ubuntu 24.04): `nginx -t` passes, an existing site on
  the same ports keeps answering, and `proxy-check` passes end to end (see below).

## What `proxy-check` tests

| # | Test | If it fails it tells you |
|---|------|--------------------------|
| 1 | Gatekeeper answers on `127.0.0.1:8080` | `gatekeeper status` / `logs` |
| 2 | DNS: the name resolves to this server; no wrong AAAA record | the record to create/fix |
| 3 | nginx listens on 443; the certificate it presents covers the name, is not expired, days left | `server_name` / reload hints |
| 4 | `https://name/healthz` through nginx to Gatekeeper (chain, name, forwarding); the same over the real internet route; http redirects to https; dashboard loads | 502 = wrong `proxy_pass`; 404/other cert = another site answers |
| 5 | Login through the proxy; cookie is `Secure` and `HttpOnly`; stays logged in on the next request | `X-Forwarded-Proto`, `TRUST_PROXY`, public address |
| 6 | Gatekeeper's public address equals the name; one trusted proxy | `gatekeeper install --reconfigure` |
| 7 | Renewal is automatic (certbot timer/cron or acme.sh) | `certbot renew --dry-run` |

Exit status is 0 when nothing failed (warnings are allowed) and 1 when something failed.

## Undo

```text
sudo rm /etc/nginx/sites-available/<name> /etc/nginx/sites-enabled/<name>   (or the conf.d file)
sudo nginx -t && sudo systemctl reload nginx
sudo certbot delete --cert-name <name>                                       (optional)
```
