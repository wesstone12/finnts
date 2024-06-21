library(tidymodels)
library(modeltime)
library(timetk)

# This toggles plot
library(tidyverse)

# Data

walmart_sales_tbl <- timetk::walmart_sales_weekly %>%
    select(id, Date, Weekly_Sales) %>%
    mutate(id = forcats::as_factor(id))

walmart_sales_tbl %>%
    group_by(id) %>%
    plot_time_series(
        Date, Weekly_Sales,
        .facet_ncol  = 2,
    )

# Split Data 80/20
splits <- time_series_split(
    walmart_sales_tbl,
    assess     = "1 year",
    cumulative = TRUE
)

splits

new_data_tbl <- walmart_sales_tbl %>%
    group_by(id) %>%
    future_frame(.length_out = "1 year") %>%
    ungroup()

recipe_ml <- recipe(Weekly_Sales ~ ., training(splits)) %>%
    step_timeseries_signature(Date) %>%
    step_rm(Date) %>%
    step_dummy(all_nominal_predictors(), one_hot = TRUE)

recipe_ml


model_xgb <- boost_tree("regression") %>%
    set_engine("xgboost")

wflw_fit_xgb <- workflow() %>%
    add_model(model_xgb) %>%
    add_recipe(recipe_ml) %>%
    fit(training(splits))

wflw_fit_xgb
models_tbl <- modeltime_table(
     wflw_fit_xgb
)

models_tbl$.model


calibration_tbl <- models_tbl %>%
    modeltime_calibrate(
        new_data = testing(splits), 
        id       = "id"
    )

calibration_tbl$.calibration_data
