# fix_k_tiles.R
# Re-interpolate K for two tiles that have all-NA values.
# Run from project root on SageMaker.

library(terra)

hist_dir   <- "data/outputs/hist"
future_dir <- "data/outputs/future"
output_dir <- "data/outputs/interpolated"
mosaic_dir <- file.path(output_dir, "mosaic")

years      <- seq(2005, 2090, by = 5)
weights    <- (years - 2005) / 85
band_names <- paste0("yr_", years)

bad_tiles <- c(
  "17817146248550000000000-0000007424",
  "17817146248550000000000-0000037120"
)

for (tid in bad_tiles) {
  cat(sprintf("Interpolating K for tile %s ...\n", tid))

  h <- rast(file.path(hist_dir,   "K", sprintf("K_%s.tif", tid)))
  f <- rast(file.path(future_dir, "K", sprintf("K_%s.tif", tid)))

  r_diff  <- f - h
  bands   <- lapply(weights, function(w) h + r_diff * w)
  r_stack <- rast(bands)
  names(r_stack) <- band_names

  out_path <- file.path(output_dir, "K", sprintf("K_%s.tif", tid))
  writeRaster(r_stack, out_path, gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
  cat(sprintf("  Wrote: %s (%d bands, %.1f%% non-NA)\n",
              out_path, nlyr(r_stack),
              100 * global(!is.na(r_stack[[1]]), "mean")[[1]]))
}

# Rebuild K VRT
cat("\nRebuilding K VRT...\n")
k_tiles <- list.files(file.path(output_dir, "K"), pattern = "\\.tif$",
                       full.names = TRUE)

vrt_path <- file.path(mosaic_dir, "K_global.vrt")
v <- vrt(k_tiles, filename = vrt_path, overwrite = TRUE)
names(v) <- band_names
cat(sprintf("  Wrote: %s\n", vrt_path))

# Quick validation via the VRT
cat(sprintf("  Bands: %d, non-NA: %.1f%%\n",
            nlyr(v), 100 * global(!is.na(v[[1]]), "mean")[[1]]))

# Rebuild the full GeoTIFF mosaic
cat("\nWriting K_global.tif (this will take a while)...\n")
tif_path <- file.path(mosaic_dir, "K_global.tif")
writeRaster(v, tif_path, gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
cat(sprintf("  Wrote: %s\n", tif_path))

# ── Sync to S3 ───────────────────────────────────────────────────────────────
library(aws.s3)

s3_bucket <- "sagemaker-gst-stage.sharing"
s3_prefix <- "serge-wiltshire/nat_for_regen_c_accumulation_data/interpolated/"

s3_files <- c(vrt_path, tif_path)
cat(sprintf("\nUploading %d files to S3...\n", length(s3_files)))

for (f in s3_files) {
  s3_key <- paste0(s3_prefix, sub(paste0(output_dir, "/"), "", f))
  use_multipart <- file.size(f) > 2e9
  tryCatch({
    put_object(file = f, bucket = s3_bucket, object = s3_key,
               multipart = use_multipart)
    cat(sprintf("  Uploaded: %s\n", s3_key))
  }, error = function(e) {
    cat(sprintf("  Failed: %s — %s\n", basename(f), conditionMessage(e)))
  })
}

cat("\nDone.\n")
