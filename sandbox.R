library(devtools)

#load the package
load_all()


#load the data
# \donttest{
data_tbl <- timetk::m4_monthly %>%
  dplyr::rename(Date = date) %>%
  dplyr::mutate(id = as.character(id)) %>%
  dplyr::filter(
    id %in% c("M1", "M2"),
    Date >= "2012-01-01",
    Date <= "2015-06-01"
  )

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


prep_models(run_info,
  models_to_run = c("arima", "ets"),
  num_hyperparameters = 1
)
prepped_models_tbl <- get_prepped_models(run_info = run_info)


train_models(run_info)

final_models(run_info)

models_tbl <- get_trained_models(run_info)

