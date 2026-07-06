# plot_global_panels.R
# Publication-quality 3-panel figures for A, B, K global mosaics.
# Each figure shows yr_000, yr_050, yr_090. Run from project root.

library(terra)
library(tidyterra)
library(tidyverse)
library(patchwork)
library(sf)

mosaic_dir <- "data/outputs/interpolated/mosaic"
out_dir    <- "data/outputs/figures"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

world <- rnaturalearth::ne_coastline(scale = "medium", returnclass = "sf")

# Band indices: yr_000 = 1, yr_050 = 6, yr_090 = 10
target_bands <- c(yr_000 = 1, yr_050 = 6, yr_090 = 10)
band_labels  <- c(yr_000 = "Year 0", yr_050 = "Year 50", yr_090 = "Year 90")

param_config <- list(
  A = list(
    file      = file.path(mosaic_dir, "A_global.tif"),
    label     = expression(italic(A) ~ "(Mg C ha"^{-1} * ")"),
    palette   = "mako",
    direction = -1
  ),
  B = list(
    file      = file.path(mosaic_dir, "B_global.tif"),
    label     = expression(italic(B) ~ "(shape)"),
    palette   = "rocket",
    direction = -1
  ),
  K = list(
    file      = file.path(mosaic_dir, "K_global.tif"),
    label     = expression(italic(K) ~ "(yr"^{-1} * ")"),
    palette   = "viridis",
    direction = 1
  )
)

base_theme <- theme_minimal(base_size = 10) +
  theme(
    panel.grid        = element_blank(),
    panel.background  = element_rect(fill = "grey95", colour = NA),
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

    ggplot() +
      geom_spatraster(data = lyr, maxcell = 5e6) +
      geom_sf(data = world, colour = "grey30", linewidth = 0.15, fill = NA) +
      scale_fill_viridis_c(
        name      = cfg$label,
        option    = cfg$palette,
        direction = cfg$direction,
        limits    = qlims,
        oob       = scales::squish,
        na.value  = "transparent",
        guide     = guide_colorbar(title.position = "top", title.hjust = 0.5)
      ) +
      coord_sf(expand = FALSE, ylim = c(-60, 80)) +
      labs(title = band_labels[band_name]) +
      base_theme
  })

  # Stack vertically with a shared legend
  p <- wrap_plots(panels, ncol = 1) +
    plot_layout(guides = "collect") &
    theme(legend.position = "bottom")

  out_path <- file.path(out_dir, paste0(param_name, "_global_panels.png"))
  ggsave(out_path, p, width = 180, height = 220, units = "mm", dpi = 300)
  cat(sprintf("  Saved: %s\n", out_path))
}

cat("\nDone.\n")
