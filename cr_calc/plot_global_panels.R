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

# Ocean polygon to mask raster values over water
land  <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf") |>
  sf::st_union()
ocean <- sf::st_difference(
  sf::st_as_sfc(sf::st_bbox(c(xmin = -180, ymin = -90, xmax = 180, ymax = 90),
                             crs = sf::st_crs(4326))),
  land
)

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
    # Downsample explicitly — geom_spatraster's maxcell can miss tile rows
    agg_factor <- max(1, round(ncell(lyr) / 5e6))
    if (agg_factor > 1) lyr <- aggregate(lyr, fact = ceiling(sqrt(agg_factor)), fun = "mean", na.rm = TRUE)

    ggplot() +
      geom_spatraster(data = lyr) +
      geom_sf(data = ocean, fill = "white", colour = NA) +
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
