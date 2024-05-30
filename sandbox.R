library(devtools)

#load the package
load_all()


#load the data
# \donttest{
data_tbl <- timetk::m4_monthly %>%
  dplyr::rename(Date = date) %>%
  dplyr::mutate(id = as.character(id)) %>%
  dplyr::filter(
    id == "M2",
    Date >= "2012-01-01",
    Date <= "2015-06-01"
  )


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


prep_models(run_info,
  models_to_run = c("arima", "ets"),
  num_hyperparameters = 1
)
prepped_models_tbl <- get_prepped_models(run_info = run_info)


train_models(run_info)

final_models(run_info)

models_tbl <- get_trained_models(run_info)




library(tidymodels)
library(modeltime)
library(timetk)     # temporal kit
library(tsibble)    # temporal kit
library(dplyr)      # pliers keep it tidy 
library(ggplot2)    # data viz
library(reticulate) # pass the python example dataset :)
library(doParallel) # model tuning made fast

train = read.csv('https://auto-arima-results.s3.amazonaws.com/M4-Hourly.csv')
test = read.csv('https://auto-arima-results.s3.amazonaws.com/M4-Hourly-test.csv')
train |> head()

n_series <- 4
uids <- paste0("H", seq(1:n_series))

# let's use for one location:
mt_train <- train |> filter(unique_id == uids[[1]]) |> mutate(ds = as.Date(ds))
mt_test  <- test  |> filter(unique_id == uids[[1]]) |> mutate(ds = as.Date(ds))

# ETS 
ets_fit <- exp_smoothing(seasonal_period = 24) |>
           set_engine("ets") |>
           fit(y ~ ds, data = mt_train)



model_tbl <- modeltime_table(
  ets_fit

)

model_tbl
# Assume models_tbl is your modeltime table
# Extracting the first model object from the table
first_model <- model_tbl$.model[[1]]

first_model

# modeltime workflow
modtime_fcst <- 
  modeltime_calibrate(
            model_tbl, 
              new_data = mt_test, 
              quiet = FALSE,
              id = "unique_id"
            ) |>
      modeltime_forecast(
        new_data = mt_test,
        conf_interval = 0.80,
        conf_method  = "conformal_default",
        conf_by_id = TRUE,
        keep_data  = TRUE
    )

modtime_fcst |> head()
