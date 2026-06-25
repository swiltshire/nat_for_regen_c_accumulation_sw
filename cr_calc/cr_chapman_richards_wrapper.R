# Wrapper to run cr_chapman_richards.Rmd as a background job in SageMaker
# RStudio. This avoids the UI crash that happens when long-running R code
# runs in the foreground.
#
# Usage in RStudio: Source → Source as Background Job

library(knitr)

rmd_file <- "cr_calc/cr_chapman_richards.Rmd"

cat("=== Wrapper started:", format(Sys.time()), "===\n")
cat("Rmd file:", rmd_file, "\n")

# Extract R code from the .Rmd and run it
r_code <- purl(rmd_file, output = tempfile(fileext = ".R"), quiet = TRUE)

tryCatch(
  source(r_code, echo = TRUE),
  error = function(e) {
    cat("\n=== WRAPPER ERROR:", conditionMessage(e), "===\n")
    cat("Traceback:\n")
    traceback()
  }
)

unlink(r_code)
cat("=== Wrapper finished:", format(Sys.time()), "===\n")
