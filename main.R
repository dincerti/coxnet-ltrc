# Setup ------------------------------------------------------------------------
rm(list = ls())

# Packages
library("data.table")
library("doParallel")
library("doRNG") # Reproducible parallel foreach loops
library("dplyr") 
library("foreach")
library("glmnet")
library("ggplot2")
library("ggpubr")
library("impute") # From bioconductor
library("knitr")
library("parallel")
library("purrr")
library("rngtools") # Required by dorng
library("rsample")
library("survival")
library("tidyr") # (>= 1.0.0) for pivot_longer() and pivot_wider()
library("xfun") # (>= 0.13.0) for cache_rds()
library("xtable")

# Sourced R files
source("R/plot_patient_followup.R")
source("R/impute_genes.R")
source("R/make_xy.R")
source("R/calibrate_sim.R")
source("R/run_sim.R")
source("R/adjust_surv.R")
source("R/tidycoef.R")
source("R/concordance.R")
source("R/calibrate.R")

# Settings
set.seed(77)
theme_set(theme_bw())
center_title <- function() theme(plot.title = element_text(hjust = 0.5))
N_SIMS <- 50

# Caching
RERUN_CACHE <- TRUE # Set to TRUE to rerun all cached results
if (!dir.exists("cache")){
  dir.create("cache")
}

# Parallel
PARALLEL <- TRUE
if (PARALLEL) {
  cl <- parallel::makeCluster(24, setup_strategy = "sequential", outfile = "simout")
  registerDoParallel(cl)
}

# Store numbers to use in text of model documentation
txt <- list() # List for in-line text statistics

# Followup plot ----------------------------------------------------------------
p_followup <- plot_patient_followup()
ggsave("figs/followup.pdf", p_followup, height = 5, width = 7)

# Load data --------------------------------------------------------------------
data <- readRDS("data.rds")

# Split data -------------------------------------------------------------------
# Using rsample package
data_split <- initial_split(data, prop = .75)
train_data <- training(data_split)
test_data <- testing(data_split)

# Clean up
rm(data_split)

# Impute genomic data ----------------------------------------------------------
train_test_imputed <- impute_genes(train_data, test_data)
train_data <- train_test_imputed$train
test_data <- train_test_imputed$test
selected_genes <- train_test_imputed$selected_genes
  
# Clean up
rm(train_test_imputed)

# Model formulas ---------------------------------------------------------------
# Small p formula
f_small <- formula(
  ~ PracticeType + index_date_year + Race + age_at_dx + RE_TP53 +
    CN_TP53 + SV_TP53 + SV_KRAS + SV_EGFR
)
vars_small <- c("Practice type: community", "Index year", "African American",
                "Other race", "White", "Age", "TP53 RE",
                "TP53 CN", "TP53 SV", "KRAS SV", "EGFR SV")

# Big p formula 
f_big <- as.formula(paste0(
  "~ PracticeType + index_date_year + Race + age_at_dx + `",
  paste(selected_genes ,collapse = "`+`"),
  "`")
)
vars_big <- c(vars_small[1:6], 
              gsub("_", ":", selected_genes))

# XY test/train data -----------------------------------------------------------
# Small p
train_small <- make_xy(train_data, f_small)
test_small <- make_xy(test_data, f_small)

# Big p
train_big <- make_xy(train_data, f_big)
test_big <- make_xy(test_data, f_big)

# Clean up
rm(train_data)
rm(test_data)

# Calibrate simulation ---------------------------------------------------------
sim_settings <- calibrate_sim(f_small, data = data)

# Cumulative hazard plot comparing different parametric models
# with Kaplan-Meier estimator
ggsave("figs/sim_calibration_cumhaz.pdf", 
       sim_settings$os_comparisons$cumhaz_plot,
       height = 5, width = 7)

# Example simulated data -------------------------------------------------------
# No predictors (intercept only model)
params <- set_params(sim_settings = sim_settings, dist = "weibullPH")
simdata <- sim_survdata(params = params, n_pats = 5000)
simdata_summary <- summarize_simdata(simdata, save = TRUE, name = "int")

# Now include predictors (and hence create informative censoring when
# using the Kaplan-Meier estimator). The design matrix X and parameters will 
# be used in the simulations that follow
x_sim <- sim_x(n_pats = 5000, sim_settings, p_bin = 10)
params <- set_params(x_sim, sim_settings, dist = "weibullPH")
simdata <- sim_survdata(x_sim, params)
simdata_summary <- summarize_simdata(simdata, save = TRUE, name = "p10")

# Run simulation for unpenalized Cox model -------------------------------------
sim_coxph_p21 <- xfun::cache_rds({
  run_sim(n_sims = N_SIMS, x = x_sim, params = params, method = "coxph")
}, file = "sim_coxph_p21.rds", rerun = RERUN_CACHE)
sim_coxph_21_summary <- summarize_sim(sim_coxph_p21, save = TRUE,
                                      model_name = "coxph_p21")
rm(sim_coxph_p21)

# Run simulation for lasso model with lambda = 0 and small p -------------------
# run_sim1(simdata, method = "coxnet", lambda = 0) # For debugging
sim_coxlasso_lambda0_p21 <- xfun::cache_rds({
  run_sim(n_sims = N_SIMS, x = x_sim, params = params, 
          method = "coxnet", lambda = c(1, 0))
}, file = "sim_coxlasso_lambda0_p21.rds", rerun = RERUN_CACHE)
coxlasso_lambda0_p21_summary <- summarize_sim(
  sim_coxlasso_lambda0_p21, save = TRUE, 
  model_name = "coxlasso_lambda0_p21"
)
rm(sim_coxlasso_lambda0_p21)

# Run simulation for lasso model with small p ----------------------------------
sim_coxlasso_p21 <- xfun::cache_rds({
  run_sim(n_sims = N_SIMS, x = x_sim, params = params, 
          method = "coxnet")
}, file = "sim_coxlasso_p21.rds", rerun = RERUN_CACHE)
sim_coxlasso_p21_summary <- summarize_sim(sim_coxlasso_p21, save = TRUE, 
                                          model_name = "coxlasso_p21")
rm(sim_coxlasso_p21)

# Run simulation for ridge model with small p ----------------------------------
sim_coxridge_p21 <- xfun::cache_rds({
  run_sim(n_sims = N_SIMS, x = x_sim, params = params, 
          method = "coxnet", alpha = 0)
}, file = "sim_coxridge_p21.rds", rerun = RERUN_CACHE)
sim_coxridge_p21_summary <- summarize_sim(sim_coxridge_p21, save = TRUE, 
                                          model_name = "coxridge_p21")
rm(sim_coxridge_p21)

# Run simulation for lasso model with big p ------------------------------------
x_sim <- sim_x(n_pats = 5000, sim_settings, p_bin = 1000)
params <- set_params(x_sim, sim_settings, dist = "weibullPH")

sim_coxlasso_p1011 <- xfun::cache_rds({
  run_sim(n_sims = N_SIMS, x = x_sim, params = params, 
          method = "coxnet")
}, file = "sim_coxlasso_p1011.rds", rerun = RERUN_CACHE)
sim_coxlasso_p1011_summary <- summarize_sim(sim_coxlasso_p1011, save = TRUE, 
                                            model_name = "coxlasso_p1011")
rm(sim_coxlasso_p1011)

# Calibration plot comparing small and big p simulation ------------------------
sim_coxlasso_calplot <- ggarrange(
  sim_coxlasso_p21_summary$calibration_plots$complete +
    ggtitle("(A) Small p") + center_title(),
  sim_coxlasso_p1011_summary$calibration_plots$complete +
    ggtitle("(B) Big p") + center_title(),
  nrow = 2, common.legend = TRUE, legend = "bottom"
)
ggsave("figs/sim_coxlasso_calibration_complete.pdf", sim_coxlasso_calplot, 
       width = 7, height = 9)

# Distribution of entry times --------------------------------------------------
p_left_trunc <- ggplot(data, aes(x = entry_days_dx)) +
  geom_histogram(binwidth = 60, colour = "white") + 
  xlab("Days between diagnosis and FMI test") + 
  ylab("Number of patients") +
  coord_cartesian(xlim = c(0, 1500))
ggsave("figs/left_trunc_hist.pdf", p_left_trunc, height = 5, width = 7)

# Number of deaths -------------------------------------------------------------
n_deaths <- sum(train_big$y[, "status"])
max_p <- n_deaths/15 # Rule of thumb for max number of predictors in Cox model

# Helper function to fit models  -----------------------------------------------
fit_models <- function(train){
  # Need separate training data frames for Cox models so that "start" column
  # is not included in model.matrix() call during survfit.coxph()
  train_df_ltrc <- data.frame(cbind(train$x, train$y))
  train_y_rc <- adjust_Surv(train$y, left_trunc = FALSE)
  train_df_rc <- data.frame(cbind(train$x, train_y_rc))
  
  # Fit models
  ptm <- proc.time()
  fits <- list(
    cox_rc = coxph(Surv(time, status) ~ ., data = train_df_rc,
                    x = TRUE),
    cox_ltrc = coxph(Surv(start, stop, status) ~ ., data = train_df_ltrc,
                     x = TRUE),
    coxlasso_rc_cv =  cv.glmnet(x = train$x, y = train_y_rc, 
                               standardize = FALSE,
                               alpha = 1, parallel = PARALLEL,
                               family = "cox"),
    coxlasso_ltrc_cv  =  cv.glmnet(x = train$x, y = train$y, 
                               standardize = FALSE,
                               alpha = 1, parallel = PARALLEL,
                               family = "cox")
  )
  print(proc.time() - ptm)
  
  # Add x and y to glmnet models for survfit 
  fits$coxlasso_rc_cv$x <- train$x
  fits$coxlasso_rc_cv$y <- train_y_rc
  fits$coxlasso_ltrc_cv$x <- train$x
  fits$coxlasso_ltrc_cv$y <- train$y
  
  # Return
  return(fits)
}

# Fit models -------------------------------------------------------------------
fits_small <- xfun::cache_rds({
  fit_models(train = train_small)
}, file = "fits_small.rds", rerun = RERUN_CACHE)

fits_big <- xfun::cache_rds({
  fit_models(train = train_big)
}, file = "fits_big.rds", rerun = RERUN_CACHE)
fits <- c(fits_small, fits_big)

# Store model fits -------------------------------------------------------------
n_fits <- length(fits)
models <- tibble(
  id = as.character(1:n_fits),
  name = rep(c("Cox", "Cox", "Cox (lasso)", "Cox (lasso)"), 2),
  left_trunc = rep(c("No", "Yes"), n_fits/2),
  left_trunc_bool = rep(c(FALSE, TRUE), n_fits/2),
  p = rep(c("Small", "Big"), each = n_fits/2),
  fit = fits,
  train = c(rep(list(train_small), n_fits/2), 
            rep(list(train_big), n_fits/2)),
  test = c(rep(list(test_small), n_fits/2), 
           rep(list(test_big), n_fits/2))
)

# Hazard ratio plot ------------------------------------------------------------
# Extract coefficients and hazard ratios
extract_coefs <- function(data, varnames){
  data %>% 
    mutate(fit = purrr::set_names(fit, left_trunc)) %>%
    pull(fit) %>%
    tidycoef(varnames = varnames) 
}

## Small
coefs_small <- extract_coefs(models %>% 
                               filter(name == "Cox (lasso)" & p == "Small"),
                             vars_small)

## Big
coefs_big <- extract_coefs(models %>% 
                             filter(name == "Cox (lasso)" & p == "Big"),
                           vars_big) %>%
  mutate(rank = dense_rank(desc(abs(estimate)))) 
vars_big_to_plot <- coefs_big %>% filter(rank <= 10) %>% pull(variable)
coefs_big <- coefs_big %>% filter(variable %in% vars_big_to_plot)

# Plot hazard ratios
plot_hr <- function(coefs){
  ggplot(data = coefs, 
         aes_string(x = "variable", col = "model")) +
    geom_point(aes(y = hr), position = position_dodge(width = 1/2)) +
    geom_hline(yintercept = 1, linetype = 2, col = "gray") +
    geom_path(aes(group = variable, y = hr),
              arrow = arrow(angle = 15, length = unit(0.3, "cm")), 
              color="gray") + 
    ylab("Hazard ratio") + coord_flip() +
    scale_color_discrete("Left truncation adjustment") +
    scale_shape_discrete("Type") + 
    theme(axis.title.y = element_blank())  +
    theme(legend.position = "bottom") +
    scale_y_continuous(breaks = seq(.8, 1.6, .1), limits = c(.8, 1.6)) 
}
p_hr_small <- plot_hr(coefs_small) + ggtitle("(A) Small p") + center_title()
p_hr_big <- plot_hr(coefs_big) + ggtitle("(B) Large p") + center_title()
p_hr <- ggarrange(p_hr_small, p_hr_big, nrow = 2, common.legend = TRUE, 
                  legend = "bottom", align = "v")
ggsave("figs/hr.pdf", p_hr, width = 7, height = 9)

# Predict survival probabilities -----------------------------------------------
my_survfit <- function(object, newx, s = "lambda.min"){
  if (inherits(object, "coxph")){
    return(survfit(object, newdata = data.frame(newx), se.fit = FALSE))
  } else{
    return(survfit(object, newx = newx, s = s, x = object$x, y = object$y))
  }
}

survfits <- xfun::cache_rds({
  pmap(models,
       function (fit, test, ...){
         my_survfit(object = fit, newx = test$x)
       })
}, file = "survfit.rds", rerun = RERUN_CACHE)
models$survfit <- survfits
survfits <- NULL

# Compute concordance ----------------------------------------------------------
my_concordance <- function(object, left_trunc, newx, newy){
  newy <- adjust_Surv(newy, left_trunc) 
  if (inherits(object, "coxph")){
    newdata <- data.frame(cbind(newx, newy))
    xb <- predict(object, newdata = newdata, type = "lp")
    return(concordance(newy ~ xb, reverse = TRUE))
  } else{
    return(concordance(object, newx = newx, newy = newy, 
                       s = "lambda.min", reverse = TRUE))
  }
}

models$concordance <- pmap(models,
  function (fit, test, left_trunc_bool, ...){
    my_concordance(object = fit, left_trunc = left_trunc_bool,
                   newx = test$x, newy = test$y)
  }
)

# Summary of model performance -------------------------------------------------
pmap_df(models,
  function(name, left_trunc, p, concordance, ...) {
           tibble(model = name, left_trunc = left_trunc,
                 p  = p, c_index = concordance$concordance)
        }
) %>%
  pivot_wider(id_cols = c("model", "p"), names_from = "left_trunc",
              values_from = c("c_index")) %>%
  xtable(digits = 3) %>%
  print(include.rownames = FALSE, include.colnames = FALSE,
        only.contents = TRUE, sanitize.text.function = identity,
        file = "tables/performance.txt")

# Calibrate survival predictions -----------------------------------------------
calplot <- function(data, newy){
  cal <- calibrate(data %>% pull(survfit), 
                   times = seq(.5, 3, .5), 
                   y = newy,
                   group_df = models %>% 
                     select(id, name, left_trunc))
  autoplot(cal, colour = "left_trunc") +
    scale_colour_discrete("Left truncation adjustment") + 
    theme(legend.position = "bottom")
}

# Cox plots
p_cal_cox_small <- calplot(models %>% filter(name == "Cox" & p == "Small"),
                           newy = test_small$y) + 
  ggtitle("(A) Small p") + center_title()
p_cal_cox_big <- calplot(models %>% filter(name == "Cox" & p == "Big"),
                         newy = test_big$y) +
  ggtitle("(B) Large p") + center_title()
p_cal_cox <- ggarrange(p_cal_cox_small, p_cal_cox_big, nrow = 2,
                       common.legend = TRUE,  legend="bottom")
ggsave("figs/calibration_cox.pdf", p_cal_cox, width = 7, height = 9)

# Cox Lasso plots
p_cal_coxlasso_small <- calplot(models %>% filter(name == "Cox (lasso)" & p == "Small"),
                              newy = test_small$y) +
  ggtitle("(A) Small p") + center_title()
p_cal_coxlasso_big <- calplot(models %>% filter(name == "Cox (lasso)" & p == "Big"),
                            newy = test_big$y) +
  ggtitle("(B) Large p") + center_title()
p_cal_coxlasso <- ggarrange(p_cal_coxlasso_small, p_cal_coxlasso_big, 
                          nrow = 2, common.legend = TRUE, legend = "bottom")
ggsave("figs/calibration_coxlasso.pdf", p_cal_coxlasso, width = 7, height = 9)

# Save text statistics ---------------------------------------------------------
txt$nPatients <- formatC(nrow(data), format = "d", big.mark = ",")
txt$nDeaths <- formatC(n_deaths, format = "d", big.mark = ",")
txt$maxP <- formatC(as.integer(max_p), format = "d", big.mark = ",")
txt$corrDxYear <- formatC(cor(data$index_date_year,
                              data$entry_days_dx), 
                          format = "f", digits = 2)
txt$entryMoreOneYear <- paste0(formatC(100 * mean(data$entry_days_dx > 365), 
                                       digits = 1, format = "f"),
                               "\\%")
txt$nCovsBig <- formatC(ncol(train_big$x), format = "d", big.mark = ",")
txt$nTrainSmall <- formatC(nrow(train_small$x), format = "d", big.mark = ",")

# Convert statistics to data frame
txtstats <- data.frame(do.call(rbind, txt))

# Output to text file to input into latex
txtstats$def <-  "\\def"
names(txtstats)[1] <- "value"
txtstats$value <- as.character(txtstats$value)
txtstats <- data.frame(def = txtstats$def, name = rownames(txtstats), value =  txtstats$value)
txtstats$output <- paste(txtstats[, 1], " ", "\\", txtstats[, 2],
                         "{", txtstats[, 3], "}", sep = "")
fileConn <- file("txtstats.txt")
writeLines(txtstats$output, fileConn)
close(fileConn)