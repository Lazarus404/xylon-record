# xylon_record

Janus-compatible `.mjr` (MJR00002) stem writer for
[Xylon](https://github.com/Lazarus404/xylon) room recording.

Ported and updated from an earlier Xirsys recording implementation; 
released for public use.

## What problem this solves

Xylon Control can start and stop a recording on a Session. This library is the
reference tap that receives publisher plaintext RTP hooks and writes one
`.mjr` stem per publisher track (audio or video) to local disk, without blocking
the live SFU path. Compose (sibling
[xylon-compose-worker](https://github.com/Lazarus404/xylon-compose-worker)) remuxes
stems after Xylon posts `recording.completed` to the shared Control webhook URL.

Wire it with:

```elixir
config :xylon,
  recording: [
    handler: XylonRecord.Handler,
    dir: "/var/lib/xylon/recordings",
    queue_max: 2000
  ]
```

## Main modules

| Module | Role |
| --- | --- |
| `XylonRecord` | Config helpers (`dir/0`, `queue_max/0`) |
| `XylonRecord.Handler` | `Xylon.Recording.Handler` implementation |
| `XylonRecord.Writer` | Per-recording GenServer; enqueue and disk I/O |
| `XylonRecord.VideoPolicy` | Simulcast / SVC layer selection + keyframe gate |
| `XylonRecord.Keyframe` | VP8 / VP9 / H.264 / AV1 keyframe detection |
| `XylonRecord.Layout` | Live layout GenServer (Plan `:record` sink ingest) |
| `XylonRecord.Layout.Ffmpeg` | External ffmpeg file + optional RTMP tee |
| `XylonRecord.Storage` | Replaceable storage behaviour |
| `XylonRecord.Storage.Local` | Local disk default |

## Video layer policy

Default archive is the **highest** SIM substream (by Plan layer index) per
publisher mid: one `.v.mjr` stem. One-SSRC VP9 uses the payload descriptor;
AV1 uses the Dependency Descriptor when present (no DD = no SVC claim, all
packets kept). Both keep max spatial, then max temporal on that spatial
(sticky as layers are observed). Unparseable VP9 / malformed DD is dropped
(no silent keep-all).

`record/start` body may set:

- `video_layer` -- integer SIM substream index, or SVC spatial index
- `rid` -- SIM RID string (`rid` wins when both are set)

Unknown rid/index falls back to highest; start does not fail. Until the first
keyframe on the chosen layer, video packets are dropped
(`skipped_before_keyframe`). Wrong-layer SIM packets count as
`skipped_wrong_layer`. There is no silent fallback to a lower layer.

Audio stems stay one file per `{publisher, mid, ssrc}`. MJR `xylon` header may
include `"layer"` and `"rid"` when known.

## MCU mix stem

When Session recording `mode` is `:tracks_and_mix` (auto when Conference
`backend_state.audio == :mcu` and `mode` is omitted, or set explicitly),
`on_mix_rtp/4` writes one additional audio `.mjr` for the room full mix with
`publisher_id` `__mcu_mix__` and `mid` from `mcu_mix_mid` (default `"0"`).
Publisher stems are still written; mix and publisher artifacts are distinct
files (`publisher_id` in the MJR header differs). Silent mix ticks do not open
a mix file.

**MCU/mix path for auto mode** means Conference `audio: :mcu` only. A spoke
SFU of a hub mix (`audio: :sfu`, `mcu_cascade: :spoke`) stays auto-`tracks`.

## RFCs

No STUN/TURN/SIP RFC. Stem framing matches the Janus Meetecho recording format
(MJR00002), compatible with `janus-pp-rec`. Media arrives as plaintext RTP after
XGW DTLS-SRTP termination ([RFC 5764](https://www.rfc-editor.org/rfc/rfc5764)).

Artifact manifests from finalize include absolute `path_or_key` plus
`kind` / `publisher_id` / `mid` / `codec` / `edge_node` for the webhook payload.
Trunk-received publishers set `via: "trunk"`; local publishers omit `via` or
use `"local"`.

## Live layout (File + RTMP)

Opt-in on `record/start` with `layout: true` (conference sessions). Xylon
installs a Plan `:record` destination (`__layout__`); Forwarder enqueues
rewritten RTP to `XylonRecord.Layout` (never blocks on ffmpeg). The layout
worker writes localhost SDP (VP8/VP9/H264 + Opus), forwards RTP to ffmpeg
(PT-normalized), and tees a fragmented `layout.mp4` plus optional `rtmp_url`.
Empty tiles use color underlays plus VP8 keepalives; codecs outside
VP8/VP9/H264 are skipped for decode (counter `layout_unsupported_codec`). With Conference `audio: :mcu`, mix RTP
(`__mcu_mix__`) is preferred over first-publisher audio. Layout runs on the
coordinator hub only in multi-home rooms. The compose worker remuxes `.mjr`
stems only and copies `layout.mp4` beside the segment output. No Chrome.

## Multi-home edges

Each cohost hub writes stems under the shared `recording_id` into the configured
`dir` (lab: shared filesystem or NFS). Xylon's Aggregator merges per-edge
artifact lists into one `recording.completed` webhook; compose remuxes all
reachable `path_or_key` values. This package only sees local decrypted RTP --
cross-edge coordination is control-plane only in
[xylon](https://github.com/Lazarus404/xylon).

## Tests

```bash
XTURN_LOCAL_DEPS=1 mix test
```

Structural MJR + Handler tests always run. The `janus-pp-rec` acceptance test is
part of the default suite and **skips** only when `janus-pp-rec` is not on
`PATH`. Install Janus post-processing tools to exercise that Phase 2 exit on
every `mix test`.

Live layout MP4 / RTMP / `ffprobe` asserts **skip** when `ffmpeg` is not on
`PATH`. Install ffmpeg (with libvpx) to exercise Phase 8 file+RTMP exits.
