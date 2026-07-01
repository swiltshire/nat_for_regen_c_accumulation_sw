# Wrapper to run cr_interpolate_params.Rmd via Rscript as a subprocess.
#
# Same pattern as cr_chapman_richards_wrapper.R — avoids mclapply fork
# crashes inside RStudio Server.
#
# Usage: run from terminal (not RStudio console):
#
#   cd /home/sagemaker-user/nat_for_regen_c_accumulation_sw
#   nohup Rscript cr_calc/cr_interpolate_params_wrapper.R > interp_wrapper.log 2>&1 &
#   tail -f data/outputs/interpolated/progress_interpolate.log

library(knitr)

rmd_file <- "cr_calc/cr_interpolate_params.Rmd"
r_file   <- tempfile(fileext = ".R")

cat("=== Extracting R code from", rmd_file, "===\n")
purl(rmd_file, output = r_file, quiet = TRUE)

cat("=== Launching Rscript subprocess ===\n")
cat("  R file:", r_file, "\n")
cat("  Started:", format(Sys.time()), "\n")

exit_code <- system2("Rscript", r_file)

cat("=== Wrapper finished:", format(Sys.time()), "===\n")
cat("  Exit code:", exit_code, "\n")

unlink(r_file)
