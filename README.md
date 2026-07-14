# Camera FTP → CMPRS XML Forwarder

Turns a Linux box (Ubuntu / Raspberry Pi OS) into an FTP drop target for
Genetec/Vigilant LPR cameras and forwards each uploaded Vigilant XML capture
to one or more CMPRS HTTP endpoints as JSON.

```
LPR camera --FTP (Vigilant XML)--> vsftpd --> /home/cameraftp/upload/
                                                    |
                                            xml_forwarder.py (systemd)
                                                    |  parse XML -> JSON
                                                    v
                                       POST to CMPRS endpoint(s)
                                                    |
                              success: move to upload/_processed/
                              delete after delete_after_seconds (default 3h)
```

## Repo contents

| File | Purpose |
|---|---|
| `setup.sh` | One-shot installer. Runs all steps with per-step OK/FAIL/SKIP output and a summary. Idempotent — safe to re-run. |
| `xml_forwarder.py` | The forwarder daemon. Polls the upload dir, converts Vigilant XML to CMPRS JSON, POSTs to all endpoints, moves sent files to `_processed/`, deletes them after a grace period. |
| `config.json` | Forwarder configuration (endpoints, camera name mapping, timings). Deployed alongside the script. |

## Quick start

```bash
git clone <this-repo>
cd <this-repo>
# 1. Edit config.json: set your real endpoint URL(s) and camera_name_map
# 2. Run the installer:
sudo ./setup.sh
```

The script will prompt once for the `cameraftp` password (first run only)
and ask before touching UFW. For unattended runs:

```bash
sudo ./setup.sh --ufw no --pasv-addr 192.168.44.5 --subnet 192.168.44.0/24
```

## What setup.sh does

1. Preconditions: root check, apt check, python3 check, auto-detect LAN IP for `pasv_address`
2. Installs `vsftpd` (skipped if present)
3. Creates the `cameraftp` user (prompts for password on first run)
4. Creates `/home/cameraftp/upload` and `upload/_processed` with correct ownership/permissions
5. Writes `/etc/vsftpd.conf` (backs up the old one), passive mode ports 40000–40100, `log_ftp_protocol=YES` for full command logging; restarts + enables vsftpd
6. Optional UFW rules for the camera subnet (ports 21 + 40000–40100)
7. Ensures `/var/log/vsftpd.log` exists
8. Creates `/home/cameraftp/XML_FORWARDER`
9. `pip3 install requests pytz --break-system-packages` (assumes python3/pip3 already installed) and verifies imports
10. Creates `/var/log/cmprs_xml_forwarder.log` owned by `cameraftp`
11. **Deploys** `xml_forwarder.py` and `config.json` from this repo into `/home/cameraftp/XML_FORWARDER/` (backs up any existing config.json, validates JSON)
12. Installs `/etc/systemd/system/xml_forwarder.service`, `daemon-reload`, **enables both `vsftpd` and `xml_forwarder` for start-on-boot**, and starts the forwarder

## Camera configuration

In the camera's FTP Upload dialog:

- **Server URL:** `ftp://<this-host-ip>:21` — the scheme MUST be `ftp://`,
  not `http://` (an `http://` URL makes the camera POST HTTP to port 21,
  which shows up in vsftpd logs as `500 HTTP protocol commands not allowed`)
- **Username:** `cameraftp`
- **Password:** whatever you set during setup
- **File Format:** Vigilant XML
- **FTP Passive Mode:** enabled

## config.json reference

| Key | Meaning | Default |
|---|---|---|
| `watch_dir` | Directory vsftpd drops XMLs into | `/home/cameraftp/upload` |
| `log_file` | Forwarder log path | `/var/log/cmprs_xml_forwarder.log` |
| `endpoints` | List of CMPRS URLs; a file is only "done" when ALL return 2xx | — |
| `camera_name_map` | Map camera name in XML → name to send to CMPRS (unmapped names pass through) | `{}` |
| `poll_seconds` | Directory poll interval | `2` |
| `delete_after_seconds` | Grace period before deleting successfully sent files | `10800` (3h) |
| `request_timeout_seconds` | HTTP timeout per POST | `10` |
| `verify_tls` | Verify endpoint TLS certs | `false` |
| `max_log_bytes` | Log rotation threshold | `104857600` (100MB) |

After editing config.json on a deployed box, restart the service:
`sudo systemctl restart xml_forwarder`. If you edit it in the repo,
just re-run `sudo ./setup.sh` — it re-deploys and restarts.

## Monitoring / troubleshooting

```bash
sudo tail -f /var/log/vsftpd.log              # FTP logins/uploads (protocol-level)
sudo tail -f /var/log/cmprs_xml_forwarder.log # parse/send/move/delete activity
systemctl status vsftpd xml_forwarder         # service health
journalctl -u xml_forwarder -n 50             # forwarder crashes/stdout
ls -lt /home/cameraftp/upload | head          # files waiting to be sent
ls -lt /home/cameraftp/upload/_processed | head  # sent, awaiting deletion
```

Reading the folders: a growing `upload/` means an endpoint problem
(files can't be sent); a growing `_processed/` means a deletion problem.

## File lifecycle

```
upload/capture.xml            new, unsent (or failing/retrying)
upload/_processed/capture.xml sent OK to all endpoints, in grace period
(deleted)                     after delete_after_seconds
```

State is tracked in `upload/.cmprs_forwarder_state.json`. If that file is
lost, anything already in `_processed/` is orphaned (never auto-deleted).
Optional safety-net cron:

```
0 * * * * find /home/cameraftp/upload/_processed -name '*.xml' -mmin +360 -delete
```
