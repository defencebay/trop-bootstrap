# Network and firewall requirements

Allow clients to reach the TROP server IP on the destination ports below, including return traffic. Apply rules on the host firewall and any firewall between clients and the server. Server, TOC, Cloud and XMPP names used by clients must resolve to the reachable server IP.

**LAN/VPN access: no application port needs to be public.** For direct Internet access, publish only the ports needed by external users or video sources, with matching NAT forwarding where applicable. An enabled listener alone is not a reason to publish it.

| Destination port | Function / effect if blocked | Public access needed when… |
| --- | --- | --- |
| TCP 443 | Web interfaces and HTTPS API become unavailable. | Users access the web/API without VPN; also required for Let's Encrypt below. |
| TCP 8089 | TAK/CoT connection fails: no positions, markers or messages over that connection. | TAK clients connect without VPN. |
| TCP 8443 | Certificate-authenticated Marti API, data packages and enabled RAVEN ingest become unavailable. | External clients use these functions without VPN. |
| TCP 8446 | New certificate enrollment fails; existing enrolled clients can still connect. | Devices enroll without VPN. |
| TCP 5223 (or 5222 with STARTTLS) | Native XMPP connection fails; web clients using server-side relays do not need these client ports. | Native XMPP clients connect without VPN; open the configured port. |
| TCP 8554 / TCP 1935 / UDP 8890 | RTSP / RTMP / SRT video fails respectively. | External video sources or viewers use that protocol without VPN; open only the protocols in use. |
| UDP 8189; TCP 8889 if used | WebRTC media fails without UDP; signaling on the dedicated 8889 endpoint fails without TCP. HTTPS signaling routes also exist on 443. | WebRTC viewers/publishers connect without VPN; allow UDP 8189 and the signaling endpoint they use. |
| TCP 9997 if used | Media gateway/API and HLS playback using this dedicated endpoint fail. HTTPS routes also exist on 443. | External clients use URLs with `:9997` without VPN. |

## Keep private or closed unless specifically needed

- **TCP 80:** HTTP access/redirects only; direct HTTPS works without it. The current installer's Let's Encrypt mode uses TCP 443, not HTTP-01 on port 80.
- **TCP 22:** SSH administration; restrict to administrators through LAN/VPN or an approved source IP.
- **Database, broker, Kubernetes and internal service ports:** keep inside the host/cluster; they are not client-facing firewall requirements.
- **TCP 8883:** MQTT TLS is not routed by the default Zarf configuration; allow it only for an explicitly configured MQTT integration.

## Outbound access

Installation and upgrades need HTTPS (TCP 443) to GitHub, its release-download endpoints and the private TROP release registry. This does not require public inbound ports. Offline operation is possible with a prepared bundle, local certificates and local data.

The optional **Let's Encrypt** mode needs public DNS pointing to the server, public inbound TCP 443 for certificate validation, and outbound HTTPS for issuance/renewal. A LAN/VPN-only installation can use the default private CA or supplied certificates instead.

Allow DNS to the site's resolver and time synchronization to the site's time source as configured. External maps, integrations and opt-in log/error reporting need outbound access to their configured services.

These are standalone/Zarf ports, without Piorun environment offsets. The installed signed release and client URLs determine which optional endpoints are used.
