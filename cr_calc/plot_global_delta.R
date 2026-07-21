# plot_global_delta.R
# Publication-quality 3-panel figure showing change (yr_2090 - yr_2005)
# for A, B, and K parameters. Run from project root.

library(terra)
library(tidyterra)
library(tidyverse)
library(patchwork)
library(sf)

# Cap terra memory so full-resolution reads (global/aggregate below) stream in
# blocks rather than buffering an entire global raster in RAM.
terraOptions(memmax = 8)

mosaic_dir <- "data/outputs/interpolated/mosaic"
out_dir    <- "data/outputs/figures"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

world <- rnaturalearth::ne_coastline(scale = "medium", returnclass = "sf")

# The forest footprint is already baked into the mosaics: the masking step set
# non-forest / ocean cells (A == 0 in the yr_2005 baseline) to NA across A, B,
# and K. Deltas therefore inherit NA where non-forest, so no re-masking is
# needed and genuine zero-change forest cells (delta == 0) are preserved. The
# baked-in NA footprint also removes ocean for free, so no rnaturalearth land
# polygon (or fragile s2 st_difference ocean) is required.

# Ordered A -> K -> B top to bottom
param_config <- list(
  A = list(
    file  = file.path(mosaic_dir, "A_global.tif"),
    title = "Maximum Potential Carbon Density (A)",
    label = expression("A (Mg C ha"^{-1} * ")")
  ),
  K = list(
    file  = file.path(mosaic_dir, "K_global.tif"),
    title = "Growth Rate Coefficient (K)",
    label = "K"
  ),
  B = list(
    file  = file.path(mosaic_dir, "B_global.tif"),
    title = "Initial Carbon Density (B)",
    label = "B"
  )
)

base_theme <- theme_minimal(base_size = 10) +
  theme(
    panel.grid        = element_blank(),
    panel.background  = element_rect(fill = "white", colour = NA),
    axis.title        = element_blank(),
    axis.text         = element_text(size = 7, colour = "grey40"),
    legend.position   = "right",
    legend.title      = element_text(size = 8),
    legend.text       = element_text(size = 7),
    legend.key.height = unit(1.2, "cm"),
    legend.key.width  = unit(0.3, "cm"),
    plot.title        = element_text(size = 11, face = "bold", hjust = 0),
    plot.margin       = margin(2, 4, 2, 4)
  )

delta_dir <- "data/outputs/interpolated/delta"
dir.create(delta_dir, recursive = TRUE, showWarnings = FALSE)

panels <- imap(param_config, function(cfg, param_name) {
  cat(sprintf("Computing delta for %s...\n", param_name))
  r <- rast(cfg$file)
  # Non-forest is already NA in both bands, so the delta is NA off the forest
  # footprint automatically.
  delta <- r[[18]] - r[[1]]

  # Save delta GeoTIFF (compressed to match the mosaics).
  delta_path <- file.path(delta_dir, paste0(param_name, "_delta.tif"))
  writeRaster(delta, delta_path, gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
  cat(sprintf("  Saved raster: %s\n", delta_path))

  qlims <- global(delta, fun = quantile, probs = c(0.01, 0.99), na.rm = TRUE)
  qlims <- as.numeric(qlims)
  # Symmetric limits for diverging scale
  abs_max <- max(abs(qlims))

  # Downsample, then convert to a data frame and plot with geom_raster.
  agg_factor <- max(1, round(ncell(delta) / 5e6))
  if (agg_factor > 1) delta_plot <- aggregate(delta, fact = ceiling(sqrt(agg_factor)), fun = "mean", na.rm = TRUE) else delta_plot <- delta
  df <- as.data.frame(delta_plot, xy = TRUE, na.rm = TRUE)
  names(df)[3] <- "value"

  ggplot() +
    geom_raster(data = df, aes(x = x, y = y, fill = value)) +
    geom_sf(data = world, colour = "grey30", linewidth = 0.15, fill = NA) +
    scale_fill_gradient2(
      name     = cfg$label,
      breaks   = scales::breaks_pretty(n = 5),
      low      = "#c62828",
      mid      = "white",
      high     = "#2e7d32",
      midpoint = 0,
      limits   = c(-abs_max, abs_max),
      oob      = scales::squish,
      na.value = "white",
      guide    = guide_colorbar(title.position = "top")
    ) +
    coord_sf(expand = FALSE, ylim = c(-60, 80)) +
    labs(title = cfg$title) +
    base_theme
})

p <- wrap_plots(panels, ncol = 1) +
  plot_annotation(
    title = "Change in Chapman-Richards parameters, 2005 to 2090",
    theme = theme(plot.title = element_text(size = 13, face = "bold", hjust = 0.5))
  )

out_path <- file.path(out_dir, "delta_yr2090_yr2005.png")
ggsave(out_path, p, width = 190, height = 240, units = "mm", dpi = 300)
cat(sprintf("Saved: %s\n", out_path))
# ── Copy saved figures to S3 ──────────────────────────────────────────────────
library(aws.s3)

s3_bucket <- "sagemaker-gst-stage.sharing"
s3_prefix <- "serge-wiltshire/nat_for_regen_c_accumulation_data/figures/"

fig_files <- list.files(out_dir, pattern = "\\.png$", full.names = TRUE)
cat(sprintf("\nUploading %d figures to S3...\n", length(fig_files)))

for (f in fig_files) {
  s3_key <- paste0(s3_prefix, basename(f))
  tryCatch({
    put_object(file = f, bucket = s3_bucket, object = s3_key)
    cat(sprintf("  Uploaded: %s\n", s3_key))
  }, error = function(e) {
    cat(sprintf("  Failed: %s — %s\n", basename(f), conditionMessage(e)))
  })
}

cat("Done.\n")
