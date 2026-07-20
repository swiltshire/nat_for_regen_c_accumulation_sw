# plot_global_panels.R
# Publication-quality 3-panel figures for A, B, K global mosaics.
# Each figure shows yr_2005, yr_2050, yr_2090. Run from project root.

library(terra)
library(tidyterra)
library(tidyverse)
library(patchwork)
library(sf)

mosaic_dir <- "data/outputs/interpolated/mosaic"
out_dir    <- "data/outputs/figures"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

world <- rnaturalearth::ne_coastline(scale = "medium", returnclass = "sf")

# Land polygon (SpatVector) used to mask ocean cells to NA before plotting.
# Do NOT build an ocean polygon via st_difference on a global bbox: under s2
# spherical geometry that produces a malformed polygon that, filled white,
# whites out most of the map and leaves only a northern stripe. Masking the
# raster with terra is reliable.
land_vect <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf") |>
  sf::st_union() |>
  terra::vect()

# Band indices: yr_2005 = 1, yr_2050 = 10, yr_2090 = 18
target_bands <- c(yr_2005 = 1, yr_2050 = 10, yr_2090 = 18)
band_labels  <- c(yr_2005 = "2005", yr_2050 = "2050", yr_2090 = "2090")

# Ordered A -> K -> B for consistency with delta plots
param_config <- list(
  A = list(
    file  = file.path(mosaic_dir, "A_global.tif"),
    title = "Maximum Potential Carbon Density (A)",
    label = expression("A (Mg C ha"^{-1} * ")"),
    low   = "#e8f5e9",
    high  = "#1b5e20"
  ),
  K = list(
    file  = file.path(mosaic_dir, "K_global.tif"),
    title = "Growth Rate Coefficient (K)",
    label = "K",
    low   = "#fff3e0",
    high  = "#e65100"
  ),
  B = list(
    file  = file.path(mosaic_dir, "B_global.tif"),
    title = "Initial Carbon Density (B)",
    label = "B",
    low   = "#0d47a1",
    high  = "#f5f0d0"
  )
)

base_theme <- theme_minimal(base_size = 10) +
  theme(
    panel.grid        = element_blank(),
    panel.background  = element_rect(fill = "white", colour = NA),
    axis.title        = element_blank(),
    axis.text         = element_text(size = 7, colour = "grey40"),
    legend.position   = "bottom",
    legend.title      = element_text(size = 9),
    legend.text       = element_text(size = 7),
    legend.key.width  = unit(2.5, "cm"),
    legend.key.height = unit(0.3, "cm"),
    plot.title        = element_text(size = 11, face = "bold", hjust = 0),
    plot.margin       = margin(2, 4, 2, 4)
  )

for (param_name in names(param_config)) {
  cfg <- param_config[[param_name]]
  cat(sprintf("Processing %s...\n", param_name))

  r <- rast(cfg$file)

  # Compute shared colour limits from band 1 (fast: sample-based)
  qlims <- global(r[[1]], fun = quantile, probs = c(0.01, 0.99), na.rm = TRUE)
  qlims <- as.numeric(qlims)

  # Build one panel per target band
  panels <- imap(target_bands, function(band_idx, band_name) {
    lyr <- r[[band_idx]]
    # Downsample, mask ocean to NA, then plot the data frame with geom_raster.
    agg_factor <- max(1, round(ncell(lyr) / 5e6))
    if (agg_factor > 1) lyr <- aggregate(lyr, fact = ceiling(sqrt(agg_factor)), fun = "mean", na.rm = TRUE)
    # Ocean cells are 0-valued in the mosaics; mask to NA so they render white.
    lyr <- terra::mask(lyr, land_vect)
    df <- as.data.frame(lyr, xy = TRUE, na.rm = TRUE)
    names(df)[3] <- "value"

    ggplot() +
      geom_raster(data = df, aes(x = x, y = y, fill = value)) +
      geom_sf(data = world, colour = "grey30", linewidth = 0.15, fill = NA) +
      scale_fill_gradient(
        name     = cfg$label,
        low      = cfg$low,
        high     = cfg$high,
        limits   = qlims,
        oob      = scales::squish,
        na.value = "white",
        guide    = guide_colorbar(title.position = "top", title.hjust = 0.5)
      ) +
      coord_sf(expand = FALSE, ylim = c(-60, 80)) +
      labs(title = band_labels[band_name]) +
      base_theme
  })

  # Stack vertically with a shared legend
  p <- wrap_plots(panels, ncol = 1) +
    plot_annotation(title = cfg$title) +
    plot_layout(guides = "collect") &
    theme(legend.position = "bottom")

  out_path <- file.path(out_dir, paste0(param_name, "_global_panels.png"))
  ggsave(out_path, p, width = 180, height = 220, units = "mm", dpi = 300)
  cat(sprintf("  Saved: %s\n", out_path))
}

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

cat("\nDone.\n")
