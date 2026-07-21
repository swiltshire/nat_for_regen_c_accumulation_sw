# cr_mask_nonforest.R
# Apply the forest footprint (A > 0) as a NA mask to the interpolated data
# products, then rebuild the global mosaics.
#
# A is maximum potential carbon density, so A == 0 in the yr_2005 baseline
# marks non-forest / nodata cells (this is also how ocean is coded). We use A
# to define ONE footprint and apply it to A, B, and K alike. Using A — rather
# than each parameter's own zeros — avoids blanking valid B == 0 cells, since B
# is a shape parameter for which 0 can be a legitimate fit.
#
# Per-tile masking runs in parallel (one work unit per tile). The UNMASKED
# originals are copied to a backup directory first, then tiles are masked in
# place via a temp file + atomic rename, so no partial write can corrupt a
# product. The step is idempotent: backups are written only once (never
# overwritten with masked data), and re-masking is a no-op (0 is already NA).
#
# Run from the terminal (NOT the RStudio console) so mclapply can fork safely:
#
#   cd /home/sagemaker-user/nat_for_regen_c_accumulation_sw
#   nohup Rscript cr_calc/cr_mask_nonforest.R > mask_wrapper.log 2>&1 &
#   tail -f data/outputs/interpolated/progress_mask.log

library(terra)
library(parallel)

# ── Configuration ─────────────────────────────────────────────────────────────
if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  project_root <- normalizePath(file.path(
    dirname(rstudioapi::getActiveDocumentContext()$path), ".."))
} else {
  project_root <- getwd()
}

interp_dir <- file.path(project_root, "data", "outputs", "interpolated")
mosaic_dir <- file.path(interp_dir, "mosaic")

params        <- c("A", "B", "K")
footprint_par <- "A"      # parameter that defines the forest footprint
baseline_band <- 1L       # yr_2005 (the baseline used to define non-forest)
band_names    <- sprintf("yr_%d", seq(2005, 2090, by = 5))

# ── Backups ─────────────────────────────────────────────────────────────────
# Copy the UNMASKED originals here before overwriting, so a failed run can be
# recovered. Guarded by existence: a backup file is written only once, so
# re-running never overwrites a good unmasked backup with masked data.
backup_unmasked <- TRUE
backup_dir      <- file.path(project_root, "data", "outputs", "interpolated_unmasked")

rebuild_mosaic <- TRUE
save_to_s3      <- TRUE
s3_bucket       <- "sagemaker-gst-stage.sharing"
s3_prefix       <- "serge-wiltshire/nat_for_regen_c_accumulation_data/interpolated/"

# ── Resources ─────────────────────────────────────────────────────────────────
terra_mem_gb <- 250
terraOptions(memmax = terra_mem_gb)

log_file <- file.path(interp_dir, "progress_mask.log")
file.create(log_file, showWarnings = FALSE)
cat(sprintf("Run started: %s\n", format(Sys.time())), file = log_file, append = TRUE)

# ── Helper: back up a file once (never overwrite an existing backup) ────────────
backup_once <- function(src, dest) {
  if (file.exists(dest)) return(invisible(FALSE))   # keep the good backup
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  file.copy(src, dest, overwrite = FALSE)
}

# ── Core function ───────────────────────────────────────────────────────────────
#' Mask one tile's A, B, K rasters to the forest footprint and overwrite in place.
#'
#' @param tile_id       Character tile identifier.
#' @param interp_dir    Path to the interpolated output directory.
#' @param params        Parameters to mask.
#' @param footprint_par Parameter defining the footprint (A).
#' @param baseline_band Band index used to define non-forest (yr_2005).
#' @param band_names    Band names to preserve on output.
#' @param backup_dir    If non-NULL, copy the unmasked tile here before masking
#'                      (only when the backup does not already exist).
#' @param log_file      Progress log path (NULL to skip).
#' @return Invisibly, tile_id on success, or a "ERROR:"-prefixed string.
mask_tile <- function(tile_id, interp_dir, params, footprint_par,
                       baseline_band, band_names, backup_dir = NULL,
                       log_file = NULL) {

  log_msg <- function(step, detail = "") {
    if (!is.null(log_file)) {
      cat(sprintf("[%s | pid=%d] %s %s — %s\n",
                  tile_id, Sys.getpid(), step, detail,
                  format(Sys.time(), "%H:%M:%S")),
          file = log_file, append = TRUE)
    }
  }

  fp_path <- file.path(interp_dir, footprint_par,
                       sprintf("%s_%s.tif", footprint_par, tile_id))
  if (!file.exists(fp_path)) {
    log_msg("SKIP", "missing footprint (A) tile")
    return(invisible(tile_id))
  }

  # Footprint: NA where the A baseline is 0, otherwise keep. Materialise in
  # memory so it no longer depends on the A file (which we overwrite below).
  fp <- classify(rast(fp_path)[[baseline_band]], cbind(0, NA))
  fp <- fp + 0        # force evaluation into memory

  for (param in params) {
    in_path <- file.path(interp_dir, param, sprintf("%s_%s.tif", param, tile_id))
    if (!file.exists(in_path)) {
      log_msg("SKIP", sprintf("%s — missing input", param))
      next
    }

    # Back up the UNMASKED original before we touch it.
    if (!is.null(backup_dir)) {
      backup_once(in_path, file.path(backup_dir, param, basename(in_path)))
    }

    r   <- rast(in_path)
    tmp <- tempfile(tmpdir = dirname(in_path), fileext = ".tif")

    # Single-layer mask is recycled across all bands of r. Streams to disk.
    m <- mask(r, fp, filename = tmp, overwrite = TRUE,
              gdal = "COMPRESS=DEFLATE", names = band_names)
    rm(m); r <- NULL

    # Atomic replace of the original product.
    if (!file.rename(tmp, in_path)) {
      file.copy(tmp, in_path, overwrite = TRUE)
      unlink(tmp)
    }
    log_msg("MASKED", param)
  }

  log_msg("DONE")
  invisible(tile_id)
}

# ── Tile discovery ──────────────────────────────────────────────────────────────
tile_files <- list.files(file.path(interp_dir, footprint_par), pattern = "\\.tif$")
tile_ids   <- sub(sprintf("^%s_(.+)\\.tif$", footprint_par), "\\1", tile_files)

if (length(tile_ids) == 0) {
  stop("No interpolated tiles found in ", file.path(interp_dir, footprint_par))
}

n_workers      <- min(max(1L, detectCores() - 1L), length(tile_ids))
per_worker_mem <- max(1L, floor(terra_mem_gb / n_workers))

cat("=== Non-forest masking ===\n")
cat(sprintf("  Tiles:    %d\n", length(tile_ids)))
cat(sprintf("  Workers:  %d (of %d cores)\n", n_workers, detectCores()))
cat(sprintf("  Per-worker terra memmax: %d GB\n", per_worker_mem))
cat(sprintf("  Backups:  %s\n", if (backup_unmasked) backup_dir else "disabled"))
cat(sprintf("  Started:  %s\n", format(Sys.time())))

# ── Parallel masking ────────────────────────────────────────────────────────────
bkp <- if (backup_unmasked) backup_dir else NULL

results <- mclapply(tile_ids, function(tid) {
  library(terra)
  terraOptions(memmax = per_worker_mem)
  tryCatch(
    mask_tile(tid, interp_dir, params, footprint_par,
              baseline_band, band_names, bkp, log_file),
    error = function(e) {
      cat(sprintf("[%s | pid=%d] FATAL: %s\n", tid, Sys.getpid(),
                  conditionMessage(e)), file = log_file, append = TRUE)
      paste("ERROR:", conditionMessage(e))
    }
  )
}, mc.cores = n_workers)

is_err <- vapply(results, function(x) is.character(x) && startsWith(x, "ERROR:"),
                 logical(1))
cat(sprintf("\n=== Masking done | %d tiles | %d errors | %s ===\n",
            length(results), sum(is_err), format(Sys.time())))
if (any(is_err)) {
  cat("Errors:\n"); invisible(lapply(results[is_err], function(e) cat("  ", e, "\n")))
  stop("Masking failed for one or more tiles — mosaic step skipped. ",
       "Unmasked originals remain in ", backup_dir)
}

# ── Rebuild global mosaics from the masked tiles ────────────────────────────────
if (rebuild_mosaic) {
  dir.create(mosaic_dir, recursive = TRUE, showWarnings = FALSE)

  # Force block-wise streaming to disk for the mosaic writes. Without this, the
  # large memmax above lets terra build each global mosaic entirely in memory,
  # which is slow to flush and an OOM risk (no swap). Streaming makes the output
  # file grow steadily instead.
  terraOptions(todisk = TRUE)

  # Cap memmax for the mosaic writes so terra streams in small blocks rather than
  # reading the whole global raster into memory. The high memmax set above is for
  # the per-tile masking; the mosaic write needs a low cap to avoid a RAM stall.
  terraOptions(memmax = 8)

  # Multithreaded, float-friendly GeoTIFF creation options. NUM_THREADS spreads
  # DEFLATE compression across all cores; PREDICTOR=3 is the floating-point
  # predictor (drop it if any product is integer-coded).
  mosaic_gdal <- c("COMPRESS=DEFLATE", "PREDICTOR=3", "ZLEVEL=6",
                   "TILED=YES", "NUM_THREADS=ALL_CPUS", "BIGTIFF=YES")

  for (param in params) {
    out_path <- file.path(mosaic_dir, sprintf("%s_global.tif", param))

    # Back up the UNMASKED mosaic once before overwriting it.
    if (backup_unmasked && file.exists(out_path)) {
      backup_once(out_path, file.path(backup_dir, "mosaic", basename(out_path)))
    }

    ptiles <- list.files(file.path(interp_dir, param), pattern = "\\.tif$",
                         full.names = TRUE)
    cat(sprintf("  %s: mosaicking %d masked tiles ... ", param, length(ptiles)))
    t0 <- Sys.time()

    vrt_path <- file.path(mosaic_dir, sprintf("%s_global.vrt", param))
    v <- vrt(ptiles, filename = vrt_path, overwrite = TRUE)
    names(v) <- band_names

    # Clear any stale/0-byte output so a failed write can't masquerade as valid.
    if (file.exists(out_path)) unlink(out_path)
    writeRaster(v, out_path, gdal = mosaic_gdal, overwrite = TRUE)

    cat(sprintf("done (%.1f min) -> %s\n",
                as.numeric(difftime(Sys.time(), t0, units = "mins")),
                basename(out_path)))
  }
  cat(sprintf("Masked mosaics written to %s\n", mosaic_dir))
}

# ── Sync masked products to S3 ──────────────────────────────────────────────────
if (save_to_s3) {
  if (!requireNamespace("aws.s3", quietly = TRUE)) install.packages("aws.s3")
  library(aws.s3)

  files <- list.files(interp_dir, pattern = "\\.tif$", recursive = TRUE,
                      full.names = TRUE)
  cat(sprintf("Syncing %d masked files to S3 ...\n", length(files)))

  for (f in files) {
    s3_key <- paste0(s3_prefix, sub(paste0(interp_dir, "/"), "", f))
    tryCatch(
      put_object(file = f, bucket = s3_bucket, object = s3_key,
                 multipart = file.size(f) > 2e9),
      error = function(e) cat(sprintf("  Failed: %s — %s\n",
                                      basename(f), conditionMessage(e)))
    )
  }
  cat("S3 sync done.\n")
}

cat(sprintf("\n=== Complete: %s ===\n", format(Sys.time())))
