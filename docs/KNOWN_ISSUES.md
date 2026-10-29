# Known issues

[← Back to README](../README.md)

This is a source/configuration snapshot of a personal player. Packaging improves defaults and removes personal state; it does not claim to resolve the earlier audit's functional bugs.

## Highest priority

| Area | Known behavior | Current mitigation |
|---|---|---|
| Optional SponsorBlock | HTTPError is caught as URLError before its specific handler; an empty/no-segments response can trigger unlimited retries. Old requests can also affect the next file. | Kept outside `portable_config/scripts`; inactive until explicitly installed. |
| Loading covers | The ffmpeg job holds the on-load hook. A missing cover can add substantial startup latency. | Disabled in the shared options file. |
| Window/PiP | Maximize can overwrite preferred dimensions; geometry anchoring/monitor detection need repair. Leaving PiP restores size, fullscreen/maximized and ontop, but re-centers the window (MPV does not report the window position). Pip_manager and window_state still hand off through short fixed delays (0.08–0.3 s), which a slow window manager can outrun. | Avoid relying on precise multi-monitor restoration; reset state if necessary. |
| History | Late thumbnail updates can reorder/recreate deleted records. Record pruning does not sweep unused thumbnails. | Treat history as convenience data; avoid deleting entries while background generation is active. |

## Other limitations

- Channel navigation and channel history independently fetch overlapping lists and may generate many speculative thumbnails. Their job deadlines/cancellation/cache limits need improvement.
- Preview keys truncate local paths and do not fingerprint source changes. Its cache cap only runs at startup. Leave previews off if these behaviors matter.
- Small history cards hide fixed-size bitmaps. Newly completed channel thumbnails may require reopening the menu. UTF-8 labels can be cut mid-character; clips shorter than ten seconds may get no local thumbnail.
- Curated streaming selectors can fail on sites without separate audio/video or without the requested codec. Quality reload's resume listener is not bound to a unique load. Explicit `ytdl://` URLs have inconsistent key handling across scripts.
- Single-instance forwarding uses a pipe configured separately from MPV's server option, has a blocking read, and can cross between installs sharing the same pipe. Both names must be changed together for isolation.
- State/history writes are direct, non-atomic rewrites. Concurrent instances or interruption during saving can lose preferences.
- Clipboard cleanup is tailored toward YouTube and may remove meaningful parameters on another site. Quoted Explorer paths and some timestamp forms need handling.
- Several weak upstream script keybindings are disabled by `no-input-default-bindings`. Game Mode and SponsorBlock manual actions require explicit mappings.
- The 4K profile is based on source width, not actual rendering load. Streaming success, HDR output and GPU frame timing depend on tools, drivers, content and display configuration.

## Validation coverage

The included regression tests cover 27 mocked cases around channel navigation, clipboard seeking, PiP cancellation/state restore and history metadata/thumbnails. Seekbar thumbnails (thumbfast) are not covered by mocked tests. Syntax checks compile active and optional Lua files without executing them. The download-path test mocks subprocesses and checks defaults/overrides.

These checks do not cover every menu callback, physical display transition, live site or renderer. Passing tests should not be read as a claim that the known issues above are fixed.
