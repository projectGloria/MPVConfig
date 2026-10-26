# Sharing notes

Prepared on 26 October 2026 as a separate source-only copy. The original player configuration was left unchanged.

## Changes made for this repository

- Omitted player/tool executables, DLLs, caches, screenshots, history, persisted preferences/window state, SponsorBlock identity and the stale test sandbox.
- Omitted the superseded `window_lock.lua.disabled` file from the script directory.
- Disabled browser cookies by default and removed the machine's Firefox profile selection and session-specific troubleshooting notes. Replaced its profile-name example in the script with a generic example.
- Disabled loading previews in the shared options file and omitted the unused `seconds` setting.
- Moved SponsorBlock into `extras/sponsorblock` so its known retry/stale-callback problems are not active by default. Kept the Lua/Python/helper sources and options for explicit opt-in.
- Removed the global `no-check-certificate` yt-dlp option from the shared mpv.conf.
- Replaced the downloader's fixed drive path with a user-folder default and added `script-opts/ytdlp_download.conf` for overrides.
- Corrected selected misleading comments about the shader-cache location, GPU assumptions, chroma scaling, interpolation and the Fast profile shortcut/restore command.
- Added documentation, an original SVG banner, privacy-oriented Git exclusions, retrieved upstream license texts and package-specific checks.

Other Lua behavior remains the existing custom setup, including the known issues. In particular, this packaging step did not repair the local-menu, window/PiP, history or optional SponsorBlock logic.

## Uploading to GitHub

Create an empty repository named **`mpv-tethys-config`**. Upload **the contents of this folder** so README.md and portable_config appear at the repository root.

For a first upload using GitHub's website, drag the source folders/files in this clean package. Include `.gitignore` and `.gitattributes` if your file picker hides dotfiles. Avoid copying used runtime files into the package before uploading. `.gitignore` protects Git-based commits; it does not filter a browser drag-and-drop upload.

If you prefer Git, run these commands from this folder after substituting your own repository URL:

```powershell
git init
git add .
git status
git commit -m "Add custom MPV Tethys configuration"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/mpv-tethys-config.git
git push -u origin main
```

The remote URL above is a placeholder. No Git repository, remote, account connection or GitHub upload was created automatically.

Review [third-party notices](THIRD_PARTY_NOTICES.md) before choosing any repository-wide license. The included licenses apply to their respective components; Tethys' overall provenance is not fully established by an explicit upstream license file.
