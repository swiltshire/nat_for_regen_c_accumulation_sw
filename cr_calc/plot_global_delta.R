# plot_global_delta.R
# Publication-quality 3-panel figure showing change (yr_090 - yr_000)
# for A, B, and K parameters. Run from project root.

library(terra)
library(tidyterra)
library(tidyverse)
library(patchwork)
library(sf)

mosaic_dir <- "data/outputs/interpolated/mosaic"
out_dir    <- "data/outputs/figures"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

world <- rnaturalearth::ne_coastline(scale = "medium", returnclass = "sf")

param_config <- list(
  A = list(
    file  = file.path(mosaic_dir, "A_global.tif"),
    title = "Change in A, present to 2090",
    label = expression("Mg C ha"^{-1})
  ),
  B = list(
    file  = file.path(mosaic_dir, "B_global.tif"),
    title = "Change in B, present to 2090",
    label = "unitless"
  ),
  K = list(
    file  = file.path(mosaic_dir, "K_global.tif"),
    title = "Change in K, present to 2090",
    label = expression("yr"^{-1})
  )
)

base_theme <- theme_minimal(base_size = 10) +
  theme(
    panel.grid        = element_blank(),
    panel.background  = element_rect(fill = "grey95", colour = NA),
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

panels <- imap(param_config, function(cfg, param_name) {
  cat(sprintf("Computing delta for %s...\n", param_name))
  r <- rast(cfg$file)
  delta <- r[[10]] - r[[1]]

  qlims <- global(delta, fun = quantile, probs = c(0.01, 0.99), na.rm = TRUE)
  qlims <- as.numeric(qlims)
  # Symmetric limits for diverging scale
  abs_max <- max(abs(qlims))

  ggplot() +
    geom_spatraster(data = delta, maxcell = 5e6) +
    geom_sf(data = world, colour = "grey30", linewidth = 0.15, fill = NA) +
    scale_fill_distiller(
      name     = cfg$label,
      breaks   = scales::breaks_pretty(n = 5),
      type     = "div",
      palette  = "RdBu",
      limits   = c(-abs_max, abs_max),
      oob      = scales::squish,
      na.value = "transparent",
      guide    = guide_colorbar(title.position = "top")
    ) +
    coord_sf(expand = FALSE, ylim = c(-60, 80)) +
    labs(title = cfg$title) +
    base_theme
})

p <- wrap_plots(panels, ncol = 1)

out_path <- file.path(out_dir, "delta_yr090_yr000.png")
ggsave(out_path, p, width = 190, height = 240, units = "mm", dpi = 300)
cat(sprintf("Saved: %s\n", out_path))
cat("Done.\n")
