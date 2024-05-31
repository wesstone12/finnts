library(devtools)
library(tidymodels)
library(modeltime)
library(timetk)
library(rsample)
# This toggles plots from plotly (interactive) to ggplot (static)

#load the package
load_all()


#load the data
# \donttest{
data_tbl <- timetk::m4_monthly %>%
  dplyr::rename(Date = date) %>%
  dplyr::mutate(id = as.character(id)) %>%
  dplyr::filter(
    id %in% c("M1", "M2"),
    Date >= "2013-01-01"
  )

unique(data_tbl$Date)

#select last 3 months of data
test_data <- data_tbl %>%
  dplyr::filter(Date >=  "2014-07-01")

#remove test data from data_tbl
data_tbl <- data_tbl %>%
  dplyr::filter(Date <  "2014-07-01")

data_tbl
#run info
run_info <- set_run_info()

prep_data(run_info,
  input_data = data_tbl,
  combo_variables = c("id"),
  target_variable = "value",
  date_type = "month",
  forecast_horizon = 3,
  recipes_to_run = "R1"
)

R1_prepped_data_tbl <- get_prepped_data(run_info,
  recipe = "R1"
)







test_data
prep_models(run_info,
  models_to_run = c("arima", "ets"),
  num_hyperparameters = 1
)
prepped_models_tbl <- get_prepped_models(run_info = run_info)



train_models(run_info)

final_models(run_info)

models_tbl <- get_trained_models(run_info)

models_tbl
models_tbl <- models_tbl %>%
  mutate(Modeltime_Table = purrr::map(Model_Fit, ~ as_modeltime_table(list(.x))))

models_tbl
library(modeltime)

models_tbl$Modeltime_Table[[2]]


# #make additional col for model_tbl that uses as_modeltime_table
# calibration_tbl <- models_tbl$Modeltime_Table[[2]] %>%
#     modeltime_calibrate(
#         new_data = test_data,
#         id = "id"
#     )

# calibration_tbl



# Check the names of the columns in test_data
print(names(test_data))



# Try the calibration again
# Assuming models_tbl and test_data are already prepared and correct
if (!is.null(models_tbl$Modeltime_Table[[2]])) {
  calibration_tbl <- try({
    modeltime_calibrate(
      models_tbl$Modeltime_Table[[2]],
      new_data = test_data,
      quiet = FALSE
    )
  })

  if (is.null(calibration_tbl)) {
    cat("Calibration failed with an error or generated warnings. Check above messages for details.\n")
  } else {
    print("Calibration successful:")
    print(calibration_tbl)
  }
} else {
  cat("Modeltime table is empty or invalid.\n")
}

calibration_tbl$.calibration_data

# Check the result
calibration_tbl%>%
    modeltime_accuracy()






forecast_tbl <- calibration_tbl %>%
    modeltime_forecast(
        new_data      = test_data,
        actual_data = data_tbl,
        conf_interval = 0.95,
        conf_method   = "conformal_split", # Default Conformal Method
        conf_by_id    = TRUE, # TRUE = local CI by ID, FALSE = global CI
        keep_data     = TRUE
    )

test_data


# ========================================================

# library(tidyverse)
# library(tidymodels)
# library(modeltime)
# library(timetk)

# This toggles plots from plotly (interactive) to ggplot (static)
# interactive <- FALSE


# Data

# walmart_sales_tbl <- timetk::walmart_sales_weekly %>%
#     select(id, Date, Weekly_Sales) %>%
#     mutate(id = forcats::as_factor(id))

# walmart_sales_tbl %>%
#     group_by(id) %>%
#     plot_time_series(
#         Date, Weekly_Sales,
#         .facet_ncol  = 2,
#         .interactive = interactive,
#     )

# walmart_sales_tbl

# # Split Data 80/20
# splits <- time_series_split(
#     walmart_sales_tbl,
#     assess     = "1 year",
#     cumulative = TRUE
# )

# splits

# testing(splits)
# training(splits)

# # new_data_tbl <- walmart_sales_tbl %>%
# #     group_by(id) %>%
# #     future_frame(.length_out = "1 year") %>%
# #     ungroup()

# # recipe_ml <- recipe(Weekly_Sales ~ ., training(splits)) %>%
# #     step_timeseries_signature(Date) %>%
# #     step_rm(Date) %>%
# #     step_dummy(all_nominal_predictors(), one_hot = TRUE)

# # recipe_ml

# # model_xgb <- boost_tree("regression") %>%
# #     set_engine("xgboost")

# # wflw_fit_xgb <- workflow() %>%
# #     add_model(model_xgb) %>%
# #     add_recipe(recipe_ml) %>%
# #     fit(training(splits))

# # wflw_fit_xgb

# # models_tbl <- modeltime_table(
# #      wflw_fit_xgb
# # )

# # models_tbl$.model

# # calibration_tbl <- models_tbl %>%
# #     modeltime_calibrate(
# #         new_data = testing(splits), 
# #         id       = "id"
# #     )

# # calibration_tbl
