# Wrapper to run cr_chapman_richards.Rmd via Rscript as a subprocess.
#
# mclapply (fork) crashes when run inside RStudio Server because RStudio is
# multi-threaded and forking a multi-threaded process is undefined behavior.
# This wrapper extracts the R code from the .Rmd and launches it as a
# standalone Rscript process that is NOT a child of RStudio Server.
#
# Usage: run this from a terminal (RStudio Terminal tab or SSH), NOT as a
# background job within RStudio.
#
#   cd /home/sagemaker-user/nat_for_regen_c_accumulation_sw
#   nohup Rscript cr_calc/cr_chapman_richards_wrapper.R > wrapper.log 2>&1 &
#   tail -f data/outputs/hist/progress_hist.log

library(knitr)

rmd_file <- "cr_calc/cr_chapman_richards.Rmd"
r_file   <- tempfile(fileext = ".R")

cat("=== Extracting R code from", rmd_file, "===\n")
purl(rmd_file, output = r_file, quiet = TRUE)

cat("=== Launching Rscript subprocess ===\n")
cat("  R file:", r_file, "\n")
cat("  Started:", format(Sys.time()), "\n")

# Run as a completely independent Rscript process
exit_code <- system2("Rscript", r_file)

cat("=== Wrapper finished:", format(Sys.time()), "===\n")
cat("  Exit code:", exit_code, "\n")

unlink(r_file)
