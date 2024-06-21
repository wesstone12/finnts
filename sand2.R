# \donttest{
library(devtools)
library(tidymodels)
library(modeltime)
library(timetk)
library(rsample)

load_all()

data_tbl <- timetk::m4_monthly %>%
  dplyr::rename(Date = date) %>%
  dplyr::mutate(id = as.character(id)) %>%
  dplyr::filter(
    id == "M2",
    Date >= "2012-01-01",
    Date <= "2015-06-01"
  )

run_info <- set_run_info()

prep_data(run_info,
  input_data = data_tbl,
  combo_variables = c("id"),
  target_variable = "value",
  date_type = "month",
  forecast_horizon = 3,
  recipes_to_run = "R1"
)

prep_models(run_info,
  models_to_run = c("meanf"),
  num_hyperparameters = 1
)


train_models(run_info,
  run_local_models = TRUE
)







final_models(run_info,
  average_models = FALSE
)

fcst_tbl <- get_forecast_data(run_info)
# }

models_tbl <- get_trained_models(run_info)