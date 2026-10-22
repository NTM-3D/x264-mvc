# x264-MVC (NTM-3D fork)

## Changes in the NTM-3D fork

This is a fork of [blenheimears/x264-mvc](https://github.com/blenheimears/x264-mvc) with Windows-focused fixes and a ready-to-use encoding script for turning ordinary 3D video files into Blu-ray 3D (MVC) streams or ISOs.

- **Windows / libavformat input fix:** non-I420 sources (e.g. NV12 from lavf) are converted to I420 and 4-plane pictures are normalized, so MVC encoding works on Windows builds.
- **Computed MVC `level_idc`** derived from the stream parameters.
- **Combined two-view rate control:** `--bitrate`, `--vbv-maxrate` and `--vbv-bufsize` describe the whole stereo stream (`--mvc-combined-bitrate`, `--mvc-combined-vbv-maxrate` and `--mvc-combined-vbv-bufsize` are explicit aliases). Both views share one CRF that is updated after every access unit, so the view that needs more bits gets them; there is no fixed per-view split. `--crf` together with a combined VBV gives constant quality with a hard combined ceiling, which is what `encode-mvc.ps1` uses. A combined VBV bucket is fed with the real size of both views; when it runs low the CRF is raised immediately, and the per-view VBV limits are divided by demand so their sum never exceeds the combined limits. `--mvc-dependent-crf-offset` biases the dependent view, `--mvc-rc-trace <csv>` writes per-access-unit sizes, CRF, view share and VBV fill, and a summary of total and per-view bitrate and minimum VBV fill is printed at the end.
- **MVC two-pass:** `--pass 1` / `--pass 2` with `--stats` keep separate statistics per view (`<stats>.base`, `<stats>.dep`) plus the first-pass bit totals (`<stats>.mvc`); pass 2 splits the bitrate between the views by what each needed in pass 1.
- **Random access:** SPS, subset SPS and PPS are repeated at every IDR so players can seek.
- **Cleaner dependent view:** the dependent view carries no access unit delimiter or SEI of its own.
- **`encode-mvc.ps1`**: one-command 3D file -> MVC / Blu-ray 3D ISO (see below)..

### `encode-mvc.ps1`

PowerShell script that pipes `ffmpeg` into `x264 --mvc` and optionally muxes a Blu-ray 3D ISO with `tsMuxeR` (original audio/subtitle tracks are carried over).

```powershell
.\encode-mvc.ps1 "Movie.FSBS.mkv"                      # -> Movie.FSBS.iso next to the input
.\encode-mvc.ps1 "Movie_htab.mp4" -Output mvc          # raw Annex B MVC stream only
.\encode-mvc.ps1 "clip.mp4" -Format ftab -EyeHeight 720 -Crf 17 -MaxBitrate 40000
```

**Format detection from the file name** (case-insensitive, same markers as the NTM-3D [mpv-android](https://github.com/NTM-3D/mpv-android) fork; a marker must be separated from other text by `.`, `_`, `-`, space etc.):

| Format | Recognized markers |
| --- | --- |
| Half SBS | `hsbs`, `half-sbs`, `half_sbs`, `sbs-half`, `sbs_half`, `half_2x1` |
| Half TAB | `htab`, `half-tab`, `half_tab`, `tab-half`, `tab_half`, `half_1x2`, `half-ou`, `half_ou`, `half-overunder` |
| Full SBS | `fsbs`, `full-sbs`, `full_sbs`, `sbs-full`, `sbs_full`, `2x1`, `full_2x1` |
| Full TAB | `ftab`, `full-tab`, `full_tab`, `tab-full`, `tab_full`, `1x2`, `full_1x2`, `full-ou`, `full_ou`, `full-overunder` |
| Generic (Half) | `3d`, `sbs` -> Half SBS; `tab`, `ou`, `overunder`, `over-under`, `over_under`, `topbottom`, `top-bottom`, `top_bottom`, `tb` -> Half TAB |

If nothing is found the script stops and asks for `-Format fsbs|hsbs|ftab|htab`, which also overrides detection.

**Any aspect ratio:** the script probes the input with `ffprobe`, splits it into the two eyes, computes each eye's display aspect ratio (respecting full/half packing and SAR), scales it to fit the Blu-ray eye frame (1920x1080, or 1280x720 with `-EyeHeight 720`) and pads with black bars. 16:9, 2.39:1, 4:3 etc. are not stretched.

**Frame rate:** `-Fps auto` (default) keeps 24 fps sources at 24 and otherwise uses 24000/1001 (Blu-ray 3D 1080p); at `-EyeHeight 720`, 50 / 59.94 fps sources are kept. Can be set explicitly to `24`, `24000/1001`, `50` or `60000/1001`.

| Parameter | Default | Description |
| --- | --- | --- |
| `-Format` | from file name | `fsbs`, `hsbs`, `ftab`, `htab` (`frames` for frame-sequential input) |
| `-Output` | `iso` | `iso` (needs tsMuxeR) or `mvc` |
| `-OutDir` | input's folder | Output directory |
| `-EyeHeight` | `1080` | Per-eye frame: 1080 (1920x1080) or 720 (1280x720) |
| `-Fps` | `auto` | Output frame rate |
| `-Crf` | `18` | Constant quality shared by both views (lower = better) |
| `-MaxBitrate` | `48000` | Combined peak rate in kbps (VBV max rate and tsMuxeR limit) |
| `-BufSize` | `24000` | Combined VBV buffer in kbit |
| `-TargetBitrate` | off | Average-bitrate mode (kbps) instead of CRF |
| `-Preset` | `slower` | x264 preset |
| `-X264`, `-FfmpegDir`, `-TsMuxer` | auto | Tool locations; otherwise searched in the script folder and `PATH` |
| `-TwoPass` | off | Two-pass encode (requires `-TargetBitrate`) |
| `-KeepTemp` | off | Keep temporary files and logs (always kept on failure; the error shows the log tails) |

Missing tools are downloaded on first use from the release pages of [this repo](https://github.com/NTM-3D/x264-mvc/releases) (`x264.exe`), [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) (`ffmpeg`, `ffprobe`) and [teaching-droid/tsMuxer](https://github.com/teaching-droid/tsMuxer) (`tsMuxeR.exe`) into a `downloaded-tools` folder next to the script (delete it to clean up); the SHA-256 of every download is verified.

Audio and subtitle tracks are carried over. Audio codecs a Blu-ray player does not accept (AAC, MP3, Opus, ...) are converted to AC-3 at 640 kbps.

---

# x264-MVC

**Experimental stereoscopic H.264/MVC encoding in the stock x264 command-line encoder.**

x264-MVC is a fork of [x264](https://code.videolan.org/videolan/x264) that adds opt-in, two-view **Multiview Video Coding (MVC)** support. It retains x264's standard CLI, presets, rate control, motion estimation, SIMD optimizations, and other performance-critical encoding code. Without `--mvc`, the ordinary AVC/2D encoding path is used.

The goal is a maintainable, upstream-friendly extension rather than a separate MVC encoder with its own command-line interface. Changes specific to stereo encoding are kept in the `mvc/` directory where possible.

> [!WARNING]
> **Experimental software.** MVC streams have been exercised with an independent software decoder and on a Sony UBP-X700 Blu-ray player, but there is no guarantee that the encoded stream is 100% spec-compliant or that it will play on all players.

## Features

- **Stock x264 frontend:** existing 2D commands, presets, input modules, video filters, and output options remain available. A representative 2D regression vector was byte-identical to unmodified x264; this is **not** a claim that every option combination has been exhaustively checked.
- **Stereoscopic encoding:** one AVC-compatible base view and one MVC dependent view, encoded using x264's existing prediction and coding machinery.
- **Inter-view prediction:** uses the reconstructed base view as a dependent-view reference for I/IDR, P, and B pictures. Each picture type can be enabled or disabled independently; all are enabled by default.
- **Stereo input layouts:** side-by-side, top/bottom, alternating frames, or two separate source files.
- **Elementary stream output:** a combined Annex B MVC stream or separate base-view `.264` and dependent-view `.mvc` streams.
- **Platform support:** the fork carries a Nix flake for x86-64 and AArch64 Linux; other platforms use x264's normal build system subject to platform testing.

## Build

### Linux / other Unix-like systems

Install the usual x264 build tools (C compiler, Make, and an assembler such as NASM on x86/x86-64). The stock x264 build detects optional input libraries, including FFmpeg/libavformat and libswscale, when present.

```sh
./configure --enable-static --disable-opencl
make -j"$(nproc)" x264
./x264 --help
```

Run the included regression suite:

```sh
python3 tests/test_stock_cli_mvc.py ./x264
```

To additionally compare 2D output against a separately compiled copy of unmodified x264:

```sh
STOCK_X264=/path/to/stock/x264 python3 tests/test_stock_cli_mvc.py ./x264
```

### Nix / NixOS

```sh
nix build .#x264-mvc -L
./result/bin/x264 --help
nix flake check -L
```

The package selects NASM explicitly on x86-64 and preserves x264's existing assembly optimizations. The flake installs available documentation files if present; it does not require any particular `README`, `LICENSE`, `COPYING`, or `AUTHORS` filename. A complete NixOS build has **not** been verified in the development environment.

## Usage

The executable is **`x264`**, not `x264-mvc`. Normal x264 syntax still applies; MVC options are additive and use the `--mvc-` prefix.

### Standard 2D H.264/AVC

```sh
x264 --preset slow --crf 20 -o film.264 film.y4m
```

### Combined stereoscopic MVC stream

For full-resolution side-by-side input (for example, 3840×1080 containing two 1920×1080 views):

```sh
x264 --mvc --mvc-layout sbs \
  --preset medium --crf 20 \
  -o stereo.264 stereo-sbs.y4m
```

### Separate AVC and dependent MVC streams

```sh
x264 --mvc --mvc-layout sbs \
  --preset slow --crf 18 \
  -o base.264 --mvc-dependent dependent.mvc stereo-sbs.y4m
```

These files contain elementary streams, **not** an M2TS, SSIF, or finished Blu-ray 3D structure.

### Other stereo layouts

```sh
# Top/bottom
x264 --mvc --mvc-layout tb -o stereo.264 top-bottom.y4m

# Alternating left/right frames
x264 --mvc --mvc-layout frames -o stereo.264 alternating.y4m

# Two independent eye files, using stock x264 input modules
x264 --mvc --mvc-layout separate --mvc-right right.y4m \
  -o stereo.264 left.y4m
```

For alternating-frame input, the inferred output frame rate is half the input rate unless you specify `--fps`. In MVC mode, stock `--frames` and `--seek` count **stereo pairs**, not individual eye frames.

### Inter-view prediction controls

All inter-view prediction modes are enabled by default. Disable a particular picture type without affecting the others:

```sh
# Disable only inter-view prediction on dependent I/IDR pictures
x264 --mvc --mvc-no-inter-i -o stereo.264 stereo-sbs.y4m

# Disable all inter-view prediction, then re-enable it only for P pictures
x264 --mvc --mvc-no-inter --mvc-inter-p \
  -o stereo.264 stereo-sbs.y4m
```

Flags are applied in command-line order.

| Option | Description |
| --- | --- |
| `--mvc` | Enable stereoscopic MVC encoding |
| `--mvc-layout sbs\|tb\|frames\|separate` | Select stereo input format (default: `sbs`) |
| `--mvc-right FILE` | Second-eye input for the `separate` layout |
| `--mvc-dependent FILE` | Write dependent-view MVC NAL units to a separate file |
| `--mvc-inter` / `--mvc-no-inter` | Enable / disable inter-view prediction for all picture types |
| `--mvc-inter-i` / `--mvc-no-inter-i` | Enable / disable inter-view prediction for dependent I/IDR pictures |
| `--mvc-inter-p` / `--mvc-no-inter-p` | Enable / disable inter-view prediction for dependent P pictures |
| `--mvc-inter-b` / `--mvc-no-inter-b` | Enable / disable inter-view prediction for dependent B pictures |

For additional encoder options, run `x264 --fullhelp`. The normal 2D x264 options are not replaced by a custom frontend.

## Current limitations

- MVC encoding supports **progressive 8-bit YUV 4:2:0** pictures. Input formats that require conversion depend on the enabled x264 input modules and filters.
- Only **two views** are supported: one AVC base view and one MVC dependent view.
- MVC output is **raw Annex B** only; disc structures, transport-stream multiplexing, and Blu-ray 3D authoring are outside this program's scope.
- To keep eye GOPs synchronized, MVC mode disables adaptive B-frame placement, scenecut insertion, and open GOP. The normal 2D path is not subject to these MVC restrictions.
- Inter-view references currently require slice-based threading and can change encode throughput. Per-view decoded-picture-buffer limits also apply.
- Joint (cross-view) two-pass rate control, `--qpfile`, pulldown, VFR, interlaced encoding, and timecode output are not currently supported in MVC mode.
- Dependent-view I/IDR pictures using inter-view prediction are coded through MVC P-slice syntax with a reconstructed base-view reference. **Compatibility with consumer hardware remains unverified.**
- Software decoding tests and a small number of bit-identical 2D comparisons do not establish comprehensive H.264/MVC conformance or 100% CLI equivalence across every build and option combination.

For implementation details and additional constraints, see [README-MVC.md](README-MVC.md).

## Development and testing

- `x264.c`: small extensions to the original CLI option parsing and encode dispatch.
- `mvc/`: MVC input coordination, output NAL handling, and related glue.
- `encoder/`, `common/`, and `x264.h`: targeted extensions for reconstructed-view references, MVC bitstream signaling, and prediction.
- `tests/test_stock_cli_mvc.py`: stock 2D CLI regression, stereo layouts, combined/split outputs, and I/P/B prediction-switch smoke tests. Optional `STOCK_X264` and `MVC_DECODER` environment variables enable additional external comparisons and software decoder checks.

Contributions are welcome, particularly around independent conformance testing, reference-picture-list correctness, performance profiling, wider stock-x264 regression coverage, and real-player compatibility. Please include a reproducible test case and note whether a change affects 2D encoding, MVC encoding, or both. No upstream acceptance or certification is implied.

## License and attribution

x264-MVC is derived from the x264 project. Upstream authorship and copyright notices are retained, and fork additions are distributed under **GNU GPL version 2 or later**. See [LICENSE](LICENSE), the original [COPYING](COPYING), and [AUTHORS](AUTHORS). x264 may also be available from its copyright holders under separate commercial terms; this fork does **not** grant such a license.

This implementation does not incorporate source code from the JMVC reference encoder. Open-source copyright licenses do **not** themselves grant AVC/MVC patent rights; evaluate the legal and interoperability requirements for your use case separately.
