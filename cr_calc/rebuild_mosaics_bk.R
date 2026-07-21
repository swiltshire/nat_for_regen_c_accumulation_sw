# rebuild_mosaics_bk.R
# Recovery step: rebuild the A, B, and K global mosaics from the already-masked
# per-tile rasters, then validate all three mosaics and sync masked products to
# S3. The masking run left B_global.tif at 0 bytes and K_global.tif stale; A was
# valid but written with a different (striped, no-predictor) encoding, so we
# rebuild it too for uniform layout across all three products.
#
# The per-tile masking is complete (see progress_mask.log), so the rebuild is a
# pure re-stitch. We stream to disk (todisk) and use multithreaded DEFLATE so
# each write is far faster than the single-threaded, in-memory write the masking
# run got stuck on.
#
# Run from the terminal so it survives the RStudio session:
#   cd ~/nat_for_regen_c_accumulation_sw
#   nohup Rscript cr_calc/rebuild_mosaics_bk.R > rebuild_bk.log 2>&1 &
#   tail -f rebuild_bk.log

library(terra)

project_root <- getwd()
interp_dir   <- file.path(project_root, "data", "outputs", "interpolated")
mosaic_dir   <- file.path(interp_dir, "mosaic")

rebuild_params  <- c("A", "B", "K")        # rebuild all three for uniform encoding
validate_params <- c("A", "B", "K")        # but validate all three at the end
band_names      <- sprintf("yr_%d", seq(2005, 2090, by = 5))
n_bands         <- length(band_names)

save_to_s3 <- TRUE
s3_bucket  <- "sagemaker-gst-stage.sharing"
s3_prefix  <- "serge-wiltshire/nat_for_regen_c_accumulation_data/interpolated/"

# Force block-wise streaming to disk. This is the key fix: the masking script's
# memmax = 250 let terra process each global mosaic entirely in memory, which is
# slow to flush and an OOM risk (swap is 0). todisk = TRUE writes incrementally,
# so the output file grows steadily.
terraOptions(todisk = TRUE)

# Multithreaded, float-friendly GeoTIFF creation options.
mosaic_gdal <- c(
  "COMPRESS=DEFLATE",
  "PREDICTOR=3",           # horizontal differencing for floating point
  "ZLEVEL=6",
  "TILED=YES",
  "NUM_THREADS=ALL_CPUS",  # multithreaded compression (GTiff driver)
  "BIGTIFF=YES"
)

# ── Rebuild B and K ─────────────────────────────────────────────────────────
for (param in rebuild_params) {
  out_path <- file.path(mosaic_dir, sprintf("%s_global.tif", param))
  vrt_path <- file.path(mosaic_dir, sprintf("%s_global.vrt", param))

  ptiles <- list.files(file.path(interp_dir, param), pattern = "\\.tif$",
                       full.names = TRUE)
  cat(sprintf("[%s] %s: mosaicking %d masked tiles ...\n",
              format(Sys.time()), param, length(ptiles)))
  t0 <- Sys.time()

  v <- vrt(ptiles, filename = vrt_path, overwrite = TRUE)
  names(v) <- band_names

  # Clear the 0-byte / stale output first so a failure can't leave a
  # half-written file masquerading as valid.
  if (file.exists(out_path)) unlink(out_path)

  writeRaster(v, out_path, gdal = mosaic_gdal, overwrite = TRUE)

  cat(sprintf("[%s] %s: done (%.1f min) -> %s (%.1f GB)\n",
              format(Sys.time()), param,
              as.numeric(difftime(Sys.time(), t0, units = "mins")),
              basename(out_path), file.size(out_path) / 1e9))
}

# ── Validate all three mosaics ──────────────────────────────────────────────
# Confirms each mosaic opens, carries the expected band count, and has real
# (non-NA) data. The non-NA check reads only band 1 to stay quick.
cat(sprintf("\n[%s] Validating mosaics ...\n", format(Sys.time())))
ok <- TRUE
for (param in validate_params) {
  p <- file.path(mosaic_dir, sprintf("%s_global.tif", param))
  if (!file.exists(p) || file.size(p) == 0) {
    cat(sprintf("  %s: MISSING or 0 bytes\n", param)); ok <- FALSE; next
  }

  r     <- rast(p)
  nb    <- nlyr(r)
  notna <- as.numeric(global(r[[1]], "notNA"))
  rng   <- as.numeric(minmax(r[[1]]))

  band_ok <- nb == n_bands
  data_ok <- is.finite(notna) && notna > 0
  if (!band_ok || !data_ok) ok <- FALSE

  cat(sprintf("  %s: %d bands (%s) | band1 non-NA cells = %s | band1 range = [%.4g, %.4g] %s\n",
              param, nb, if (band_ok) "OK" else sprintf("EXPECTED %d", n_bands),
              format(notna, big.mark = ",", scientific = FALSE),
              rng[1], rng[2], if (data_ok) "OK" else "-- ALL NA / EMPTY!"))
}
if (!ok) stop("Validation failed for one or more mosaics — S3 sync skipped.")
cat(sprintf("[%s] Validation passed.\n", format(Sys.time())))

# ── Sync masked products to S3 ──────────────────────────────────────────────
# Re-uploads every masked .tif (tiles + mosaics), since the tiles were masked in
# place and the copies on S3 are otherwise still unmasked.
if (save_to_s3) {
  if (!requireNamespace("aws.s3", quietly = TRUE)) install.packages("aws.s3")
  library(aws.s3)

  files <- list.files(interp_dir, pattern = "\\.tif$", recursive = TRUE,
                      full.names = TRUE)
  cat(sprintf("[%s] Syncing %d masked files to S3 ...\n",
              format(Sys.time()), length(files)))

  n_fail <- 0L
  for (f in files) {
    s3_key <- paste0(s3_prefix, sub(paste0(interp_dir, "/"), "", f))
    tryCatch(
      put_object(file = f, bucket = s3_bucket, object = s3_key,
                 multipart = file.size(f) > 2e9),
      error = function(e) {
        n_fail <<- n_fail + 1L
        cat(sprintf("  Failed: %s — %s\n", basename(f), conditionMessage(e)))
      }
    )
  }
  cat(sprintf("[%s] S3 sync done (%d failures).\n", format(Sys.time()), n_fail))
}

cat(sprintf("\n[%s] Rebuild + validation + sync complete.\n", format(Sys.time())))
