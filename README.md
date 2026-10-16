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
- MVC two-pass rate control, `--qpfile`, pulldown, VFR, interlaced encoding, and timecode output are not currently supported in MVC mode.
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
