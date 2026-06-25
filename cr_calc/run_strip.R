#!/usr/bin/env Rscript
# Process one strip of one tile. Called from bash — each invocation is a
# fully independent R process (no fork, no sockets, no serialization).
#
# Usage:
#   Rscript cr_calc/run_strip.R <tile_id> <xmin> <xmax> <ymin> <ymax> \
#           <strip_suffix> <input_dir> <output_dir> <log_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 9) {
  stop("Expected 9 arguments: tile_id xmin xmax ymin ymax strip_suffix input_dir output_dir log_file")
}

tile_id      <- args[1]
crop_ext     <- as.numeric(args[2:5])
strip_suffix <- args[6]
input_dir    <- args[7]
output_dir   <- args[8]
log_file     <- args[9]

library(terra)
library(minpack.lm)
terraOptions(memmax = 2)

source("cr_calc/functions.R")

calc_cr_tile(
  tile_id      = tile_id,
  input_dir    = input_dir,
  output_dir   = output_dir,
  crop_ext     = crop_ext,
  strip_suffix = strip_suffix,
  log_file     = log_file,
  app_cores    = 1L
)
