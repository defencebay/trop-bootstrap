# Ports to allow — TROP Standalone (Zarf)

**LAN/VPN only → no public application ports.** Allow the ports below from client networks to the server IP, with return traffic.

**Internet access without VPN → publish only the ports for features you use:**

| Port | For | Public when |
| --- | --- | --- |
| **443 TCP** | Web / API | Web access without VPN, or Let's Encrypt certificates |
| **8089 TCP + 8443 TCP** | TAK connection / data packages | TAK clients connect without VPN |
| **8446 TCP** | Device enrollment | Devices enroll without VPN |
| **5223 TCP** (or **5222 TCP**) | Native XMPP | XMPP clients connect without VPN |
| **8554 TCP / 1935 TCP / 8890 UDP** | RTSP / RTMP / SRT video | Video uses that protocol without VPN |
| **8189 UDP** | WebRTC video/audio | WebRTC is used without VPN |
| **8889 TCP / 9997 TCP** | Dedicated video endpoints | Client URLs use these ports without VPN; HTTPS routes on 443 also exist |

**Keep private:** SSH **22 TCP**, databases, broker and Kubernetes. **80 TCP** is optional for HTTP; HTTPS works without it. **8883 TCP** is not needed by default.

Blocking a port disables its feature. DNS names must resolve to the server IP reachable by clients. Installation/updates need outbound **443 TCP** to GitHub and the TROP registry; Let's Encrypt also needs outbound HTTPS and public DNS pointing to the server.
