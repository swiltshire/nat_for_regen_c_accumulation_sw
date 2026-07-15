# Chapman-Richards Carbon Accumulation Curve Fitting

Fits pixel-level Chapman-Richards (CR) growth curves to above-ground carbon (AGC)
estimates from random forest outputs, for natural forest regeneration carbon modeling.

## Overview

For each pixel the model is:

$$\text{AGC}(t) = A \cdot (1 - B \cdot e^{-Kt})^3$$

where *A* (asymptote), *K* (growth rate), and *B* (shape) are estimated independently
per pixel via nonlinear least squares (Levenberg-Marquardt). Inputs are GEE-exported
regional tiles at ~1 km resolution for two climate scenarios (**hist**, **future**).

## Repository structure

```
cr_calc/
  cr_chapman_richards.Rmd          # CR parameter fitting notebook
  cr_chapman_richards_wrapper.R    # Launches fitting as standalone Rscript
  cr_interpolate_params.Rmd        # Interpolate A,B,K between hist and future
  cr_interpolate_params_wrapper.R  # Launches interpolation as standalone Rscript
  plot_global_panels.R             # 3-panel maps of A, K, B at 2005/2050/2090
  plot_global_delta.R              # Delta maps (2090 − 2005) for A, K, B
setup/
  fetch_input_data.Rmd             # Data pipeline: GCS -> S3 -> SageMaker (rclone)
data/
  inputs/
    future/                        # 360 tiles: age_005_*.tif ... age_100_*.tif (20 bands each)
    hist/                          # Same structure, historical climate scenario
  outputs/                         # Written by the notebooks (gitignored)
    hist/{A,B,K,...}/              # Single-band param tiles from CR fitting
    future/{A,B,K,...}/            # Single-band param tiles from CR fitting
    interpolated/{A,B,K}/          # 18-band interpolated tiles (yr_2005 ... yr_2090)
    interpolated/mosaic/           # Global mosaics: A_global.tif, B_global.tif, K_global.tif
```

## Inputs

Each input file covers a ~62×62 degree regional tile at 0.00833 degree (~1 km) resolution:

| Property | Value |
|---|---|
| Naming | `age_{AGE}_{TILE_ID}.tif` |
| Age steps | 5, 10, ..., 100 years (20 files per tile) |
| Bands per file | 20 (random forest replicates `sd_001`-`sd_020`) |
| Tiles per scenario | 18 |
| Data points per pixel | 400 (20 ages x 20 replicates) |

## Outputs

Seven single-band GeoTIFFs per tile, written to `data/outputs/{scenario}/{param}/`:

| File | Contents |
|---|---|
| `A_{tile_id}.tif` | CR asymptote (max potential AGC) |
| `K_{tile_id}.tif` | Growth rate |
| `B_{tile_id}.tif` | Shape parameter |
| `A_error_{tile_id}.tif` | Std. error of A |
| `K_error_{tile_id}.tif` | Std. error of K |
| `B_error_{tile_id}.tif` | Std. error of B |
| `convergence_{tile_id}.tif` | NLS iteration count (1-3) or 4 = failed |

## Usage

### Local (smoke test)

Open `cr_calc/cr_chapman_richards.Rmd` with `test_mode <- TRUE` and run
interactively. Crops one tile to a 150x150 pixel window, completes in
~35 seconds, and produces diagnostic plots.

### SageMaker (production)

On SageMaker, the notebook is run as a standalone Rscript process via the
wrapper script. This avoids mclapply fork crashes that occur inside RStudio
Server's multi-threaded environment.

1. Set config in `cr_calc/cr_chapman_richards.Rmd`:

```r
test_mode    <- FALSE
scenarios    <- c("hist", "future")   # both run in parallel (36 workers)
terra_mem_gb <- 250                   # ~75% of instance RAM
```

2. Launch from the **terminal** (not RStudio console):

```bash
cd /home/sagemaker-user/nat_for_regen_c_accumulation_sw
nohup Rscript cr_calc/cr_chapman_richards_wrapper.R > wrapper.log 2>&1 &
tail -f data/outputs/*/progress_*.log
```

Both scenarios run simultaneously — 36 parallel workers (18 tiles × 2
scenarios) via `mclapply`. `nohup` ensures it survives disconnects.
RStudio stays responsive.

**Recommended instance:** `ml.r5.12xlarge` (48 vCPUs, 384 GB RAM, ~$3.60/hr).

3. After completion, sync outputs to S3 (Section 9 of the notebook uses
   the `aws.s3` R package — no CLI tools required).

### Interpolation (after CR fitting)

After CR fitting is complete for both scenarios, interpolate A, B, K between
hist (2005) and future (2090) at 5-year intervals:

1. Set config in `cr_calc/cr_interpolate_params.Rmd`:

```r
test_mode    <- FALSE
terra_mem_gb <- 250
```

2. Launch from terminal:

```bash
cd /home/sagemaker-user/nat_for_regen_c_accumulation_sw
nohup Rscript cr_calc/cr_interpolate_params_wrapper.R > interp_wrapper.log 2>&1 &
tail -f data/outputs/interpolated/progress_interpolate.log
```

Outputs: 18-band GeoTIFFs in `data/outputs/interpolated/{A,B,K}/` (per-tile)
and `data/outputs/interpolated/mosaic/{A,B,K}_global.tif` (mosaicked global),
with bands `yr_2005` through `yr_2090` at 5-year intervals. Completes in
seconds per tile (pure raster algebra); mosaic step runs after all tiles finish.

### Data pipeline

See `setup/fetch_input_data.Rmd` for transferring input data from GCS to S3
(one-time via `rclone`) and syncing from S3 to SageMaker local storage
(each session).

## Dependencies

```r
install.packages(c("terra", "tidyverse", "minpack.lm",
                   "tidyterra", "patchwork", "sf", "rnaturalearth"))
```

`parallel` is included with base R.

Tested on R >= 4.3. `terra` requires GDAL.
