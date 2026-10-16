# Network: eliminating micro-stutter for good

> 🌐 [中文](zh-CN/network.md) ｜ **English**

Game streaming is far less tolerant of a network than you would expect: a slightly higher average
latency is harmless. **Jitter and burst packet loss** are the killers.

## 1. macOS AWDL: the culprit nobody suspects

### Symptoms

- A brief hitch every few seconds, with no discernible pattern
- Packet loss looks low (even `ping` drops nothing)
- The server log shows **burst packet loss**: 4–13 packets dropped at once
- Sunshine/Moonlight's adaptive bitrate keeps ratcheting down — the picture gets blurrier and
  blurrier — and the stutter stays exactly the same

### Cause

Every Mac runs something called **AWDL** (Apple Wireless Direct Link): the **direct radio link**
behind AirDrop, Handoff, Universal Clipboard, and AirPlay. It periodically retunes the Wi-Fi radio
to a "social channel" for roughly **100 milliseconds** — and during those 100 ms, every packet is
dropped.

```
$ ifconfig awdl0
awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                  ↑↑↑ that UP flag is the proof it is enabled
```

### Measured results

Same Mac, same ping target, same 60 packets:

| | jitter max | jitter mdev |
|---|---|---|
| AWDL on | **63.7 ms** | 12.7 ms |
| AWDL off | **7.6 ms** | 1.4 ms |

The knock-on effect on the stream: Moonlight's adaptive bitrate recovered from a throttled
**5 Mbps** all the way back to **52 Mbps**, and dropped frames went to zero.

### Why FEC can't save you

Sunshine has forward error correction (`fec_percentage`), which can patch up **scattered** loss.
What AWDL produces is **bursts**: a single video frame is only 4–7 packets, and 4–13 of them
disappear at once, so FEC has nothing to work with. In testing, raising FEC from 40% to 80% changed
nothing — the problem is the *shape* of the loss, not the amount.

The log looks like this:

```
Unrecoverable frame 1106: 2+2=4 received < 5 needed     <- a frame needs only 5 packets
Unrecoverable frame 1515: 0+1=1 received < 5 needed     <- 4 of those 5 packets were lost
                                    ↑
                          the number after the + is how many FEC recovered
```

### Two fixes

**Option A: disable it while streaming, restore it afterwards** (recommended — AirDrop keeps working)

```bash
sudo bash scripts/mac/install-awdl-guard.sh
```

It installs a LaunchDaemon: when it detects that Moonlight is streaming it runs
`ifconfig awdl0 down`, and `up` again once you quit.

**Option B: leave it off permanently**

```bash
sudo ifconfig awdl0 down
```

The price: AirDrop / Handoff / Universal Clipboard stop working.

### How to verify

```bash
# With a stream running, ping the Mac from the server and watch the jitter
ping -c 60 -i 0.1 <Mac-IP>
# mdev should be < 2ms; if it's > 10ms, it's time to look at AWDL
```

## 2. Choosing a bitrate

Starting points (tune them together with `fec_percentage`):

| Link | Suggested bitrate | FEC |
|---|---|---|
| Gigabit Ethernet | 50000–80000 Kbps | 20 |
| 100 Mbps Ethernet | 35000–45000 Kbps | 30 |
| Wi-Fi 5GHz, same room | 25000–40000 Kbps | 40–60 |
| Wi-Fi, mediocre signal | 15000–25000 Kbps | 60 |

Be aware that **FEC inflates your real bandwidth usage in proportion**: with
`fec_percentage = 40`, a 35 Mbps video stream actually occupies ~49 Mbps.

```ini
# ~/.config/sunshine/sunshine.conf
fec_percentage = 40
```

## 3. Reading the log to identify the problem

In Moonlight's log (`/tmp/Moonlight-*.log`):

| Log line | Meaning | What to do |
|---|---|---|
| `Network dropped 1 frame (frame N)` | One frame didn't receive all of its packets | Raise FEC |
| `Unrecoverable frame N: a+b=c received < d needed` | Too much loss for FEC to repair | Lower the bitrate / fix AWDL |
| `Unable to recover audio data block` | A whole group of audio packets was lost | Same as above (audio packets travel in groups of 4) |
| `Connection status update: 1` | The client has decided the link got worse | The adaptive bitrate will start dropping |

## 4. Things not to overlook

**Stream over the LAN, not through a NAT-traversal tunnel.** How to check (on the server):

```bash
# See which NIC the video stream leaves through
for i in eno1 tailscale0; do
  a=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0); sleep 5
  b=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0)
  echo "$i: $(( (b-a)*8/5/1000000 )) Mbps"
done
```

The video should be leaving through your LAN interface (tens of Mbps), with the Tailscale/tunnel
interface near 0. Tailscale is convenient, but the moment traffic falls back to a DERP relay, both
latency and jitter look terrible.

**Don't let your 5GHz channel collide with a neighbor's.** macOS can list the networks around you:

```bash
system_profiler SPAirPortDataType | grep -A3 "Other Local Wi-Fi Networks"
```

If your channel overlaps a neighbor's 80MHz block (say you're on 157 and they're on 149 — both
inside the 149-161 span), moving to 36-48 or 100-112 will be much cleaner.

**Wired always wins.** Put a USB-C Ethernet adapter on the Mac and every problem above disappears
at once.
