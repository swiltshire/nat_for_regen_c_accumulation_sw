# validate_outputs.R
# Quick validation: check all expected output files exist and visualize global mosaics.
# Run from project root on SageMaker after pipeline completes.

library(terra)
library(tidyverse)

cat("=== Output Validation ===\n\n")

# --- 1. Define expected files ---

tile_ids <- c(

"17817146248550000000000-0000000000",
"17817146248550000000000-0000007424",
"17817146248550000000000-0000014848",
"17817146248550000000000-0000022272",
"17817146248550000000000-0000029696",
"17817146248550000000000-0000037120",
"17817146248550000007424-0000000000",
"17817146248550000007424-0000007424",
"17817146248550000007424-0000014848",
"17817146248550000007424-0000022272",
"17817146248550000007424-0000029696",
"17817146248550000007424-0000037120",
"17817146248550000014848-0000000000",
"17817146248550000014848-0000007424",
"17817146248550000014848-0000014848",
"17817146248550000014848-0000022272",
"17817146248550000014848-0000029696",
"17817146248550000014848-0000037120"
)

cr_params   <- c("A", "B", "K", "A_error", "B_error", "K_error", "convergence")
interp_params <- c("A", "B", "K")
scenarios   <- c("hist", "future")

# Build expected file lists
cr_files <- expand_grid(scenario = scenarios, param = cr_params, tile = tile_ids) |>
  mutate(path = file.path("data", "outputs", scenario, param, paste0(param, "_", tile, ".tif")))

interp_files <- expand_grid(param = interp_params, tile = tile_ids) |>
  mutate(path = file.path("data", "outputs", "interpolated", param, paste0(param, "_", tile, ".tif")))

mosaic_files <- tibble(
  param = interp_params,
  path  = file.path("data", "outputs", "interpolated", "mosaic", paste0(param, "_global.tif"))
)

# --- 2. Check existence ---

check_files <- function(df, label) {
  df <- df |> mutate(exists = file.exists(path))
  n_ok   <- sum(df$exists)
  n_total <- nrow(df)
  status <- if (n_ok == n_total) "OK" else "MISSING FILES"
  cat(sprintf("  %-30s %d / %d  [%s]\n", label, n_ok, n_total, status))

  missing <- df |> filter(!exists)
  if (nrow(missing) > 0) {
    cat("    Missing:\n")
    walk(missing$path, ~ cat("      ", .x, "\n"))
  }
  invisible(df)
}

cat("File inventory:\n")
cr_check     <- check_files(cr_files,     "CR fitting tiles")
interp_check <- check_files(interp_files, "Interpolated tiles")
mosaic_check <- check_files(mosaic_files, "Global mosaics")

# --- 3. Quick stats on global mosaics ---

cat("\nGlobal mosaic summaries:\n")
for (i in seq_len(nrow(mosaic_files))) {
  f <- mosaic_files$path[i]
  if (!file.exists(f)) {
    cat(sprintf("  %s — MISSING, skipped\n", basename(f)))
    next
  }
  r <- rast(f)
  cat(sprintf("\n  %s\n", basename(f)))
  cat(sprintf("    Dimensions : %d rows × %d cols × %d bands\n", nrow(r), ncol(r), nlyr(r)))
  cat(sprintf("    CRS        : %s\n", crs(r, describe = TRUE)$name))
  cat(sprintf("    Extent     : %.2f, %.2f, %.2f, %.2f (xmin, xmax, ymin, ymax)\n",
              ext(r)[1], ext(r)[2], ext(r)[3], ext(r)[4]))

  # Sample stats from band 1 (yr_2005) and the last band (yr_2090)
  for (b in c(1, nlyr(r))) {
    vals <- values(r[[b]], na.rm = TRUE)
    n_valid <- sum(!is.na(vals))
    n_total <- ncell(r)
    cat(sprintf("    Band %2d    : %.1f%% non-NA | range [%.3f, %.3f] | mean %.3f\n",
                b, 100 * n_valid / n_total,
                min(vals, na.rm = TRUE), max(vals, na.rm = TRUE), mean(vals, na.rm = TRUE)))
  }
}

# --- 4. Visualize global mosaics (band 1 = yr_000) ---

cat("\nPlotting global mosaics (band 1 = yr_2005)...\n")

png("data/outputs/validation_mosaics.png", width = 2400, height = 2400, res = 200)
par(mfrow = c(3, 1), mar = c(2, 2, 3, 1))

for (i in seq_len(nrow(mosaic_files))) {
  f <- mosaic_files$path[i]
  if (!file.exists(f)) {
    plot.new()
    title(main = paste(mosaic_files$param[i], "— MISSING"))
    next
  }
  r <- rast(f)[[1]]
  plot(r, main = paste0(mosaic_files$param[i], "_global — Band 1 (yr_2005)"),
       col = hcl.colors(100, "viridis"), maxcell = 5e6)
}
dev.off()

cat("Saved: data/outputs/validation_mosaics.png\n")
cat("\n=== Validation complete ===\n")
