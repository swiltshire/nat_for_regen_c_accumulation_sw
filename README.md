# Chapman-Richards Carbon Accumulation Curve Fitting

Fits pixel-level Chapman-Richards (CR) growth curves to above-ground carbon (AGC)
estimates from random forest outputs, for natural forest regeneration carbon modeling.

## Overview

For each pixel the model is:

$$\text{AGC}(t) = A \cdot (1 - B \cdot e^{-Kt})^3$$

where *A* (asymptote), *K* (growth rate), and *B* (shape) are estimated independently
per pixel via nonlinear least squares. Inputs are GEE-exported regional tiles at
~1 km resolution for two climate scenarios (**hist**, **future**).

## Repository structure

```
cr_calc/
  cr_chapman_richards.Rmd   # Main notebook — run this
data/
  inputs/
    future/                 # 360 tiles: age_005_*.tif … age_100_*.tif (20 bands each)
    hist/                   # Same structure, historical climate scenario
  outputs/                  # Written by the notebook (gitignored)
```

## Inputs

Each input file covers a ~62°×62° regional tile at 0.00833° (~1 km) resolution:

| Property | Value |
|---|---|
| Naming | `age_{AGE}_{TILE_ID}.tif` |
| Age steps | 5, 10, …, 100 years (20 files per tile) |
| Bands per file | 20 (random forest replicates `sd_001`–`sd_020`) |
| Tiles per scenario | 18 |
| Data points per pixel | 400 (20 ages × 20 replicates) |

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
| `convergence_{tile_id}.tif` | NLS iteration count (1–3) or 4 = failed |

## Usage

Open `cr_calc/cr_chapman_richards.Rmd` and set the options in **Section 2**:

```r
test_mode   <- TRUE    # FALSE for full production run
scenario    <- "future"  # or "hist"
n_cores     <- ...     # auto-detected; override if needed
terra_mem_gb <- 8      # increase for large instances
```

Run all chunks, or knit the document. For the second scenario, change `scenario`
and re-run.

### Smoke test

With `test_mode <- TRUE` the notebook crops one tile to a 150×150 pixel window
centred on the densest valid data, runs the full fitting pipeline (~35 s on a
laptop), and produces diagnostic plots of fitted curves vs observed scatter.

### SageMaker

On a large Linux instance (e.g. `ml.r5.24xlarge`) the notebook auto-selects the
`"pixel"` parallel strategy, which passes all available cores to `terra::app()`
for within-tile pixel parallelism. Set `terra_mem_gb` to ~75% of available RAM.

```r
project_root <- "/home/ec2-user/SageMaker/nat_for_regen_c_accumulation_sw"
terra_mem_gb <- 500   # example for 768 GB instance
```

## Dependencies

```r
install.packages(c("terra", "tidyverse", "parallel", "doParallel", "foreach", "tictoc"))
```

Tested on R ≥ 4.3. `terra` requires GDAL — ensure system dependencies are present.
