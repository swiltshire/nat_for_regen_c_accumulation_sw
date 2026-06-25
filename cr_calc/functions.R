# Chapman-Richards curve fitting functions
# Sourced by run_strip.R and the main notebook

chapman_richards <- function(t, A, K, B) {
  A * (1 - B * exp(-K * t))^3
}

attempt_nls <- function(pix_y, age_v, a_start, k_start = 0.05, b_start = 0.75) {
  lower <- c(a = a_start * 0.9, k = 0.01, b = 0.2)
  upper <- c(a = a_start * 1.1, k = 0.10, b = 1.0)
  fit <- try(minpack.lm::nlsLM(
    pix_y ~ a * (1 - b * exp(-k * age_v))^3,
    start   = list(a = a_start, k = k_start, b = b_start),
    lower   = lower,
    upper   = upper,
    control = minpack.lm::nls.lm.control(maxiter = 500)
  ), silent = TRUE)
  if (inherits(fit, "try-error")) return(NULL)
  cf <- coef(fit)
  se <- tryCatch(summary(fit)$coefficients[, "Std. Error"],
                 error = function(e) rep(NA_real_, 3))
  c(A = unname(cf["a"]), K = unname(cf["k"]), B = unname(cf["b"]),
    A_err = se[1], K_err = se[2], B_err = se[3])
}

fit_cr_pixel <- function(pix_y, age_v, max_pot) {
  na_r <- c(A = NA_real_, K = NA_real_, B = NA_real_,
            A_err = NA_real_, K_err = NA_real_, B_err = NA_real_,
            convergence = NA_real_)
  zero_r <- c(A = 0, K = 0, B = 0, A_err = 0, K_err = 0, B_err = 0,
              convergence = 0)
  if (all(is.na(pix_y)) | any(is.na(pix_y))) return(na_r)
  if (is.na(max_pot) | max_pot <= 0) return(zero_r)
  r1 <- attempt_nls(pix_y, age_v, a_start = max_pot)
  if (is.null(r1)) return(c(na_r[1:6], convergence = 4))
  if (r1["A"] >= max_pot * 0.9 & r1["A"] <= max_pot * 1.1) return(c(r1, convergence = 1))
  r2 <- attempt_nls(pix_y, age_v, a_start = r1["A"], k_start = r1["K"], b_start = r1["B"])
  if (is.null(r2)) return(c(r1, convergence = 4))
  if (r2["A"] >= r1["A"] * 0.9 & r2["A"] <= r1["A"] * 1.1) return(c(r2, convergence = 2))
  r3 <- attempt_nls(pix_y, age_v, a_start = r2["A"], k_start = r2["K"], b_start = r2["B"])
  if (is.null(r3)) return(c(r2, convergence = 4))
  c(r3, convergence = 3)
}

calc_cr_tile <- function(tile_id,
                         input_dir,
                         output_dir,
                         ages         = seq(5, 100, by = 5),
                         n_bands      = 20,
                         log_file     = NULL,
                         app_cores    = 1L,
                         test_crop_n  = 0L,
                         crop_ext     = NULL,
                         strip_suffix = "") {

  age_v <- rep(ages, each = n_bands)

  age_files <- file.path(input_dir, sprintf("age_%03d_%s.tif", ages, tile_id))

  missing_files <- age_files[!file.exists(age_files)]
  if (length(missing_files) > 0) {
    msg <- sprintf("[%s] SKIPPED — missing files:\n  %s\n",
                   tile_id, paste(missing_files, collapse = "\n  "))
    message(msg)
    if (!is.null(log_file)) cat(msg, file = log_file, append = TRUE)
    return(invisible(NULL))
  }

  agc_stack <- rast(age_files)

  if (!is.null(crop_ext)) {
    agc_stack <- crop(agc_stack, ext(crop_ext))
  } else if (test_crop_n > 0) {
    probe   <- rast(age_files[length(age_files)])[[1]]
    agg_fct <- max(1L, floor(min(nrow(probe), ncol(probe)) / 75L))
    probe_agg <- aggregate(probe, fact = agg_fct, fun = "max", na.rm = TRUE)
    agg_vals  <- values(probe_agg, mat = FALSE)
    best_cell <- which.max(replace(agg_vals, is.na(agg_vals), 0))
    if (length(best_cell) == 0 || max(agg_vals, na.rm = TRUE) == 0) {
      e  <- ext(agc_stack)
      rx <- res(agc_stack)[1]; ry <- res(agc_stack)[2]
      crop_ext <- ext(e[1], e[1] + test_crop_n*rx, e[4] - test_crop_n*ry, e[4])
    } else {
      best_row <- rowFromCell(probe_agg, best_cell)
      best_col <- colFromCell(probe_agg, best_cell)
      mid_row  <- (best_row - 0.5) * agg_fct
      mid_col  <- (best_col - 0.5) * agg_fct
      e  <- ext(agc_stack)
      rx <- res(agc_stack)[1]; ry <- res(agc_stack)[2]
      half <- test_crop_n / 2
      x_mid <- e[1] + (mid_col - 0.5) * rx
      y_mid <- e[4] - (mid_row - 0.5) * ry
      crop_ext <- ext(x_mid - half*rx, x_mid + half*rx,
                      y_mid - half*ry, y_mid + half*ry)
    }
    agc_stack <- crop(agc_stack, crop_ext)
  }

  # Self-contained pixel fitting function (all helpers inlined via local())
  cr_app_func <- local({
    av <- age_v
    .attempt_nls <- function(pix_y, age_v, a_start, k_start = 0.05, b_start = 0.75) {
      lower <- c(a = a_start * 0.9, k = 0.01, b = 0.2)
      upper <- c(a = a_start * 1.1, k = 0.10, b = 1.0)
      fit <- try(minpack.lm::nlsLM(
        pix_y ~ a * (1 - b * exp(-k * age_v))^3,
        start   = list(a = a_start, k = k_start, b = b_start),
        lower   = lower, upper = upper,
        control = minpack.lm::nls.lm.control(maxiter = 500)
      ), silent = TRUE)
      if (inherits(fit, "try-error")) return(NULL)
      cf <- coef(fit)
      se <- tryCatch(summary(fit)$coefficients[, "Std. Error"],
                     error = function(e) rep(NA_real_, 3))
      c(A = unname(cf["a"]), K = unname(cf["k"]), B = unname(cf["b"]),
        A_err = se[1], K_err = se[2], B_err = se[3])
    }
    .fit_cr_pixel <- function(pix_y, age_v, max_pot) {
      na_r <- c(A=NA_real_,K=NA_real_,B=NA_real_,A_err=NA_real_,K_err=NA_real_,B_err=NA_real_,convergence=NA_real_)
      if (all(is.na(pix_y)) | any(is.na(pix_y))) return(na_r)
      if (is.na(max_pot) | max_pot <= 0) return(c(A=0,K=0,B=0,A_err=0,K_err=0,B_err=0,convergence=0))
      r1 <- .attempt_nls(pix_y, age_v, a_start = max_pot)
      if (is.null(r1)) return(c(na_r[1:6], convergence = 4))
      if (r1["A"] >= max_pot*0.9 & r1["A"] <= max_pot*1.1) return(c(r1, convergence=1))
      r2 <- .attempt_nls(pix_y, age_v, a_start=r1["A"], k_start=r1["K"], b_start=r1["B"])
      if (is.null(r2)) return(c(r1, convergence=4))
      if (r2["A"] >= r1["A"]*0.9 & r2["A"] <= r1["A"]*1.1) return(c(r2, convergence=2))
      r3 <- .attempt_nls(pix_y, age_v, a_start=r2["A"], k_start=r2["K"], b_start=r2["B"])
      if (is.null(r3)) return(c(r2, convergence=4))
      c(r3, convergence=3)
    }
    function(x) {
      .fit_cr_pixel(pix_y = x, age_v = av, max_pot = max(x, na.rm = TRUE))
    }
  })

  label <- paste0(tile_id, strip_suffix)
  msg_start <- sprintf("[%s] Starting CR fit — %s\n", label, format(Sys.time(), "%H:%M:%S"))
  if (!is.null(log_file)) cat(msg_start, file = log_file, append = TRUE)

  result <- app(agc_stack, fun = cr_app_func, cores = app_cores)
  names(result) <- c("A", "K", "B", "A_error", "K_error", "B_error", "convergence")

  param_dirs <- file.path(output_dir, names(result))
  invisible(lapply(param_dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

  for (param in names(result)) {
    out_path <- file.path(output_dir, param,
                          sprintf("%s_%s%s.tif", param, tile_id, strip_suffix))
    writeRaster(result[[param]], out_path, gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
  }

  msg_done <- sprintf("[%s] Complete — %s\n", label, format(Sys.time(), "%H:%M:%S"))
  message(msg_done)
  if (!is.null(log_file)) cat(msg_done, file = log_file, append = TRUE)

  invisible(tile_id)
}
