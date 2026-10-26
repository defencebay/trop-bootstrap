# Ports to allow — TROP Standalone (Zarf)

**LAN/VPN only → no public application ports.** Allow the ports below from client networks to the server IP, with return traffic.

**Internet access without VPN → publish only the ports for features you use:**

| Port | For | Public when |
| --- | --- | --- |
| **443 TCP** | Web / API | Web access without VPN, or Let's Encrypt certificates |
| **8089 TCP + 8443 TCP** | TAK connection / data packages | TAK clients connect without VPN |
| **8446 TCP** | Device enrollment | Devices enroll without VPN |
| **5223 TCP** | TROP mobile XMPP chat | TROP mobile clients connect without VPN |
| **8554 TCP / 1935 TCP / 8890 UDP** | RTSP / RTMP / SRT video | Video uses that protocol without VPN |
| **8189 UDP** | WebRTC video/audio | WebRTC is used without VPN |
| **8889 TCP / 9997 TCP** | Dedicated video endpoints | Client URLs use these ports without VPN; HTTPS routes on 443 also exist |

**5222 TCP:** optional for other clients explicitly configured for XMPP STARTTLS; not required by TROP mobile apps. Zarf enables both listeners; the server uses 5222 internally.

**Keep private:** SSH **22 TCP**, databases, broker and Kubernetes. **80 TCP** is optional for HTTP; HTTPS works without it. **8883 TCP** is not needed by default.

Blocking a port disables its feature. DNS names must resolve to the server IP reachable by clients. Installation/updates need outbound **443 TCP** to GitHub and the TROP registry; Let's Encrypt also needs outbound HTTPS and public DNS pointing to the server.

## WebRTC addresses and DNS

In a signed release that includes the WebRTC address update, the private installer
automatically uses the LAN address and the hostname from `MEDIA_URL` (normally the
TROP Server hostname). The media Pod resolves that name at startup. If DNS is not
available yet, it keeps LAN playback available and reports the missing name.
The public launcher only downloads and verifies the selected release; downloading
a newer launcher does not add this behavior to an older installation.

For additional VPN, LAN or public entry points, edit the private deployment config
`/etc/trop/zarf-config.yaml` (or its encrypted equivalent):

```yaml
package:
  deploy:
    set:
      MEDIA_WEBRTC_ADDITIONAL_HOSTS: "203.0.113.10,vpn.example.com"
```

Run `trop config apply` after changing this value to persist the list into the
media workload; apply can restart its Pod. Every address must route to this
installation's ICE listener, normally UDP 8189. Successful HTTPS access to TOC
does not prove that media traffic can reach it.

With the matching Doctor version, run `trop-doctor webrtc-check`. If DNS becomes
available or changes after startup, `trop-doctor webrtc-refresh` re-resolves the
list already persisted in the workload and updates runtime addresses without a
Pod restart. Refresh does not import edits from `/etc/trop`. An older package
needs an upgrade before the new setting can be applied; check release notes and
`trop-doctor --help` before using the new commands.

DNS must resolve inside the media Pod, and external playback must be tested from
the intended client network. For the full procedure, see the
[Standalone runbook](https://github.com/defencebay/trop-infra/blob/master/docs/zarf-install-update-runbook.md#webrtc-addresses-and-disconnected-dns).
