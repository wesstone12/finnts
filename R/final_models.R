#' Final Models
#'
#' Select Best Models and Prep Final Outputs
#'
#' @param run_info run info using the [set_run_info()] function.
#' @param average_models If TRUE, create simple averages of individual models.
#' @param max_model_average Max number of models to average together. Will
#'   create model averages for 2 models up until input value or max number of
#'   models ran.
#' @param weekly_to_daily If TRUE, convert a week forecast down to day by
#'   evenly splitting across each day of week. Helps when aggregating
#'   up to higher temporal levels like month or quarter.
#' @param parallel_processing Default of NULL runs no parallel processing and
#'   forecasts each individual time series one after another. 'local_machine'
#'   leverages all cores on current machine Finn is running on. 'spark'
#'   runs time series in parallel on a spark cluster in Azure Databricks or
#'   Azure Synapse.
#' @param inner_parallel Run components of forecast process inside a specific
#'   time series in parallel. Can only be used if parallel_processing is
#'   set to NULL or 'spark'.
#' @param num_cores Number of cores to run when parallel processing is set up.
#'   Used when running parallel computations on local machine or within Azure.
#'   Default of NULL uses total amount of cores on machine minus one. Can't be
#'   greater than number of cores on machine minus 1.
#'
#' @return Final model outputs are written to disk.
#'
#' @examples
#' \donttest{
#' data_tbl <- timetk::m4_monthly %>%
#'   dplyr::rename(Date = date) %>%
#'   dplyr::mutate(id = as.character(id)) %>%
#'   dplyr::filter(
#'     Date >= "2013-01-01",
#'     Date <= "2015-06-01"
#'   )
#'
#' run_info <- set_run_info()
#'
#' prep_data(run_info,
#'   input_data = data_tbl,
#'   combo_variables = c("id"),
#'   target_variable = "value",
#'   date_type = "month",
#'   forecast_horizon = 3
#' )
#'
#' prep_models(run_info,
#'   models_to_run = c("arima", "ets"),
#'   back_test_scenarios = 3
#' )
#'
#' train_models(run_info,
#'   run_global_models = FALSE
#' )
#'
#' final_models(run_info)
#' }
#' @export
final_models <- function(run_info,
                         average_models = TRUE,
                         max_model_average = 3,
                         weekly_to_daily = TRUE,
                         parallel_processing = NULL,
                         inner_parallel = FALSE,
                         num_cores = NULL) {
  cli::cli_progress_step("Selecting Best Models")

  # check input values
  check_input_type("run_info", run_info, "list")
  check_input_type("average_models", average_models, "logical")
  check_input_type("max_model_average", max_model_average, "numeric")
  check_input_type("num_cores", num_cores, c("NULL", "numeric"))
  check_parallel_processing(
    run_info,
    parallel_processing,
    inner_parallel
  )

  # get combos
  combo_list <- list_files(
    run_info$storage_object,
    paste0(
      run_info$path, "/forecasts/*", hash_data(run_info$experiment_name), "-",
      hash_data(run_info$run_name), "*_models.", run_info$data_output
    )
  ) %>%
    tibble::tibble(
      Path = .,
      File = fs::path_file(.)
    ) %>%
    tidyr::separate(File, into = c("Experiment", "Run", "Combo", "Type"), sep = "-", remove = TRUE) %>%
    dplyr::filter(Combo != hash_data("All-Data")) %>%
    dplyr::pull(Combo) %>%
    unique()

  # get run splits
  model_train_test_tbl <- read_file(run_info,
    path = paste0(
      "/prep_models/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
      "-train_test_split.", run_info$data_output
    ),
    return_type = "df"
  )

  # check if a previous run already has necessary outputs
  prev_combo_list <- list_files(
    run_info$storage_object,
    paste0(
      run_info$path, "/forecasts/*", hash_data(run_info$experiment_name), "-",
      hash_data(run_info$run_name), "*average_models.", run_info$data_output
    )
  ) %>%
    tibble::tibble(
      Path = .,
      File = fs::path_file(.)
    ) %>%
    tidyr::separate(File, into = c("Experiment", "Run", "Combo", "Run_Type"), sep = "-", remove = TRUE) %>%
    dplyr::pull(Combo) %>%
    unique()

  current_combo_list <- combo_list

  current_combo_list_final <- setdiff(
    current_combo_list,
    prev_combo_list
  )

  prev_log_df <- read_file(run_info,
    path = paste0("logs/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name), ".csv"),
    return_type = "df"
  )

  date_type <- prev_log_df$date_type
  forecast_approach <- prev_log_df$forecast_approach
  negative_forecast <- prev_log_df$negative_forecast
  run_global_models <- prev_log_df$run_global_models
  run_local_models <- prev_log_df$run_local_models
  run_ensemble_models <- prev_log_df$run_ensemble_models

  if ((length(current_combo_list_final) == 0 & length(prev_combo_list) > 0) | sum(colnames(prev_log_df) %in% "weighted_mape")) {

    # check if input values have changed
    current_log_df <- tibble::tibble(
      average_models = average_models,
      max_model_average = max_model_average,
    ) %>%
      data.frame()

    prev_log_df <- prev_log_df %>%
      dplyr::select(colnames(current_log_df)) %>%
      data.frame()

    if (hash_data(current_log_df) == hash_data(prev_log_df)) {
      cli::cli_alert_info("Best Models Already Selected")
      return(cli::cli_progress_done())
    } else {
      stop("Inputs have recently changed in 'final_models', please revert back to original inputs or start a new run with 'set_run_info'",
        call. = FALSE
      )
    }
  }

  # parallel run info
  par_info <- par_start(
    run_info = run_info,
    parallel_processing = parallel_processing,
    num_cores = num_cores,
    task_length = length(current_combo_list)
  )

  cl <- par_info$cl
  packages <- par_info$packages
  `%op%` <- par_info$foreach_operator

  # submit tasks
  best_model_tbl <- foreach::foreach(
    x = current_combo_list,
    .combine = "rbind",
    .packages = packages,
    .errorhandling = "stop",
    .verbose = FALSE,
    .inorder = FALSE,
    .multicombine = TRUE,
    .noexport = NULL
  ) %op%
    {
      combo <- x

      # get individual and ensemble model predictions
      train_test_id_list <- model_train_test_tbl %>%
        dplyr::filter(Run_Type %in% c("Back_Test", "Future_Forecast")) %>%
        dplyr::mutate(Train_Test_ID = as.numeric(Train_Test_ID)) %>%
        dplyr::pull(Train_Test_ID) %>%
        unique()

      single_model_tbl <- NULL
      if (run_local_models) {
        single_model_tbl <- tryCatch(
          {
            read_file(run_info,
              path = paste0(
                "/forecasts/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
                "-", combo, "-single_models.", run_info$data_output
              ),
              return_type = "df"
            )
          },
          warning = function(w) {
            # do nothing
          },
          error = function(e) {
            NULL
          }
        )
      }

      ensemble_model_tbl <- NULL
      if (run_ensemble_models) {
        ensemble_model_tbl <- tryCatch(
          {
            read_file(run_info,
              path = paste0(
                "/forecasts/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
                "-", combo, "-ensemble_models.", run_info$data_output
              ),
              return_type = "df"
            )
          },
          warning = function(w) {
            # do nothing
          },
          error = function(e) {
            NULL
          }
        )
      }

      global_model_tbl <- NULL
      if (run_global_models) {
        global_model_tbl <- tryCatch(
          {
            read_file(run_info,
              path = paste0(
                "/forecasts/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
                "-", combo, "-global_models.", run_info$data_output
              ),
              return_type = "df"
            )
          },
          warning = function(w) {
            # do nothing
          },
          error = function(e) {
            NULL
          }
        )
      }

      local_model_tbl <- single_model_tbl %>%
        rbind(ensemble_model_tbl)

      # check if model averaging already happened
      if ("Best_Model" %in% colnames(local_model_tbl %>% rbind(global_model_tbl))) {
        # see if average models file exists and add to model tbl
        average_model_tbl <- tryCatch(
          {
            read_file(run_info,
              path = paste0(
                "/forecasts/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
                "-", combo, "-average_models.", run_info$data_output
              ),
              return_type = "df"
            )
          },
          warning = function(w) {
            # do nothing
          },
          error = function(e) {
            NULL
          }
        )

        local_model_tbl <- local_model_tbl %>%
          rbind(average_model_tbl)

        best_model_check <- TRUE
      } else {
        best_model_check <- FALSE
      }

      # combine all forecasts
      predictions_tbl <- local_model_tbl %>%
        rbind(global_model_tbl) %>%
        dplyr::select(Combo, Model_ID, Model_Name, Model_Type, Recipe_ID, Train_Test_ID, Date, Forecast, Target) %>%
        dplyr::filter(Train_Test_ID %in% train_test_id_list)

      # get model list
      if (!is.null(local_model_tbl)) {
        local_model_list <- local_model_tbl %>%
          dplyr::pull(Model_ID) %>%
          unique()
      } else {
        local_model_list <- NULL
      }

      if (!is.null(global_model_tbl)) {
        global_model_list <- global_model_tbl %>%
          dplyr::pull(Model_ID) %>%
          unique()
      } else {
        global_model_list <- NULL
      }

      final_model_list <- c(local_model_list, global_model_list)

      # simple model averaging
      if (average_models & length(final_model_list) > 1 & !best_model_check) {

        # create model combinations list
        model_combinations <- tibble::tibble()

        for (number in 2:min(length(final_model_list), max_model_average)) {
          temp <- data.frame(gtools::combinations(v = final_model_list, n = length(final_model_list), r = number))

          temp <- temp %>%
            tidyr::unite(Model_Combo, colnames(temp)) %>%
            dplyr::select(Model_Combo) %>%
            tibble::tibble()

          model_combinations <- rbind(model_combinations, temp)
        }

        iter_list <- model_combinations %>%
          dplyr::pull(Model_Combo)

        par_info <- par_start(
          run_info = run_info,
          parallel_processing = if (inner_parallel) {
            "local_machine"
          } else {
            NULL
          },
          num_cores = num_cores,
          task_length = nrow(iter_list)
        )

        inner_cl <- par_info$cl
        inner_packages <- par_info$packages
        `%op%` <- par_info$foreach_operator

        averages_tbl <- foreach::foreach(
          x = iter_list,
          .combine = "rbind",
          .packages = inner_packages,
          .errorhandling = "remove",
          .verbose = FALSE,
          .inorder = FALSE,
          .multicombine = TRUE,
          .noexport = NULL
        ) %op%
          {

            # get list of models to average
            model_list <- strsplit(x, "_")[[1]]

            # create model average
            final_tbl <- predictions_tbl %>%
              dplyr::filter(Model_ID %in% model_list) %>%
              dplyr::group_by(Combo, Train_Test_ID, Date) %>%
              dplyr::summarise(
                Target = mean(Target, na.rm = TRUE),
                Forecast = mean(Forecast, na.rm = TRUE)
              ) %>%
              dplyr::mutate(Model_ID = x) %>%
              dplyr::select(Combo, Model_ID, Train_Test_ID, Date, Target, Forecast) %>%
              dplyr::ungroup()

            return(final_tbl)
          } %>%
          base::suppressPackageStartupMessages()

        par_end(inner_cl)
      } else {
        averages_tbl <- NULL
      }

      # choose best model
      final_predictions_tbl <- predictions_tbl %>%
        dplyr::select(Combo, Model_ID, Train_Test_ID, Date, Forecast, Target) %>%
        rbind(averages_tbl)

      back_test_mape <- final_predictions_tbl %>%
        dplyr::mutate(
          Train_Test_ID = as.numeric(Train_Test_ID),
          Target = ifelse(Target == 0, 0.1, Target)
        ) %>%
        dplyr::filter(Train_Test_ID != 1) %>%
        dplyr::mutate(MAPE = round(abs((Forecast - Target) / Target), digits = 4))

      best_model_mape <- back_test_mape %>%
        dplyr::group_by(Model_ID, Combo) %>%
        dplyr::mutate(
          Combo_Total = sum(abs(Target), na.rm = TRUE),
          weighted_MAPE = (abs(Target) / Combo_Total) * MAPE
        ) %>%
        dplyr::summarise(Rolling_MAPE = sum(weighted_MAPE, na.rm = TRUE)) %>%
        dplyr::arrange(Rolling_MAPE) %>%
        dplyr::ungroup() %>%
        dplyr::group_by(Combo) %>%
        dplyr::slice(1) %>%
        dplyr::ungroup()

      best_model_tbl <- best_model_mape %>%
        dplyr::mutate(Best_Model = "Yes") %>%
        dplyr::select(Combo, Model_ID, Best_Model)

      back_test_mape_final <- back_test_mape %>%
        dplyr::left_join(best_model_tbl,
          by = c("Combo", "Model_ID")
        ) %>%
        dplyr::mutate(
          Best_Model = ifelse(!is.na(Best_Model), "Yes", "No"),
          Train_Test_ID = Train_Test_ID - 1
        ) %>%
        dplyr::rename(Back_Test_Scenario = Train_Test_ID) %>%
        dplyr::group_by(Combo, Model_ID, Back_Test_Scenario) %>%
        dplyr::mutate(Horizon = dplyr::row_number()) %>%
        dplyr::ungroup() %>%
        dplyr::select(Combo, Model_ID, Back_Test_Scenario, Horizon, Date, Forecast, Target, MAPE, Best_Model)

      best_model_final_tbl <- tibble::tibble(Model_ID = stringr::str_split(best_model_tbl$Model_ID, "_")[[1]]) %>%
        dplyr::mutate(
          Combo = best_model_tbl$Combo,
          Best_Model = "Yes"
        ) %>%
        tidyr::separate(col = "Model_ID", into = c("Model_Name", "Recipe_ID", "Model_Type"), sep = "--", remove = FALSE)

      # if a simple model average is the most accurate store the results
      if (nrow(best_model_final_tbl) > 1) {
        model_avg_final_tbl <- final_predictions_tbl %>%
          dplyr::right_join(best_model_tbl,
            by = c("Combo", "Model_ID")
          ) %>%
          dplyr::mutate(
            Combo_ID = Combo,
            Model_Name = "NA",
            Model_Type = "local",
            Recipe_ID = "simple_average",
            Hyperparameter_ID = "NA",
            Best_Model = "Yes"
          ) %>%
          dplyr::group_by(Combo_ID, Model_ID, Train_Test_ID) %>%
          dplyr::mutate(Horizon = dplyr::row_number()) %>%
          dplyr::ungroup() %>%
          create_prediction_intervals(model_train_test_tbl) %>%
          convert_weekly_to_daily(date_type, weekly_to_daily)

        write_data(
          x = model_avg_final_tbl,
          combo = unique(model_avg_final_tbl$Combo_ID),
          run_info = run_info,
          output_type = "data",
          folder = "forecasts",
          suffix = "-average_models"
        )

        if (!is.null(single_model_tbl)) {
          single_model_final_tbl <- single_model_tbl %>%
            dplyr::mutate(Best_Model = "No") %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = single_model_final_tbl,
            combo = unique(single_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-single_models"
          )
        }

        if (!is.null(ensemble_model_tbl)) {
          ensemble_model_final_tbl <- ensemble_model_tbl %>%
            dplyr::mutate(Best_Model = "No") %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = ensemble_model_final_tbl,
            combo = unique(ensemble_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-ensemble_models"
          )
        }

        if (!is.null(global_model_tbl)) {
          global_model_final_tbl <- global_model_tbl %>%
            dplyr::mutate(Best_Model = "No") %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = global_model_final_tbl,
            combo = unique(global_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-global_models"
          )
        }
      } else { # choose the most accurate individual model and write outputs

        final_model_tbl <- tibble::tibble(Model_ID = final_model_list) %>%
          dplyr::left_join(
            best_model_final_tbl %>%
              dplyr::select(Model_ID, Best_Model),
            by = "Model_ID"
          ) %>%
          dplyr::mutate(Best_Model = ifelse(!is.na(Best_Model), "Yes", "No"))

        if (!is.null(single_model_tbl)) {
          single_model_final_tbl <- single_model_tbl %>%
            remove_best_model() %>%
            dplyr::left_join(final_model_tbl,
              by = "Model_ID"
            ) %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = single_model_final_tbl,
            combo = unique(single_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-single_models"
          )
        }

        if (!is.null(ensemble_model_tbl)) {
          ensemble_model_final_tbl <- ensemble_model_tbl %>%
            remove_best_model() %>%
            dplyr::left_join(final_model_tbl,
              by = "Model_ID"
            ) %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = ensemble_model_final_tbl,
            combo = unique(ensemble_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-ensemble_models"
          )
        }

        if (!is.null(global_model_tbl)) {
          global_model_final_tbl <- global_model_tbl %>%
            remove_best_model() %>%
            dplyr::left_join(final_model_tbl,
              by = "Model_ID"
            ) %>%
            create_prediction_intervals(model_train_test_tbl) %>%
            convert_weekly_to_daily(date_type, weekly_to_daily)

          write_data(
            x = global_model_final_tbl,
            combo = unique(global_model_final_tbl$Combo),
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-global_models"
          )
        }
      }

      return(best_model_mape)
    } %>%
    base::suppressPackageStartupMessages()

  # clean up any parallel run process
  par_end(cl)

  # reconcile hierarchical forecasts
  if (forecast_approach != "bottoms_up") {
    cli::cli_progress_step("Reconciling Hierarchical Forecasts")

    reconcile_hierarchical_data(
      run_info,
      parallel_processing,
      forecast_approach,
      negative_forecast,
      num_cores
    )
  }

  # update logging file
  log_df <- read_file(run_info,
    path = paste0("logs/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name), ".csv"),
    return_type = "df"
  ) %>%
    dplyr::mutate(
      average_models = average_models,
      max_model_average = max_model_average,
      weighted_mape = base::mean(best_model_tbl$Rolling_MAPE, na.rm = TRUE)
    )

  write_data(
    x = log_df,
    combo = NULL,
    run_info = run_info,
    output_type = "log",
    folder = "logs",
    suffix = NULL
  )
}

#' Create prediction intervals
#'
#' @param fcst_tbl forecast table to use to create prediction intervals
#' @param train_test_split train test split
#'
#' @return data frame with prediction intervals
#' @noRd
# create_prediction_intervals <- function(fcst_tbl, train_test_split, conf_levels = c(0.80, 0.95), split_ratio = 0.8) {
#   # Do a 60/40 split for calibration and test sets for now. May be worth more calibration data in the future

#     # Extract the Train_Test_IDs for the Back_Test run type
#     back_test_ids <- train_test_split %>%
#     dplyr::filter(Run_Type == "Back_Test") %>%
#     dplyr::pull(Train_Test_ID)

#   # Filter and order forecast table by Date... probably not necessary lol
#   fcst_tbl_filtered <- fcst_tbl %>%
#     dplyr::filter(Train_Test_ID %in% back_test_ids) %>%
#     dplyr::arrange(Date)

#   # Initialize lists to store quantile values and coverage results
#   quantiles_list <- list()
#   coverage_results <- list()
# cat("\n=====================CONFORMAL TESTING=====================\n")
#   # Loop over each combination of Combo and Model_ID
#   for (combo in unique(fcst_tbl_filtered$Combo)) {
#     for (model_id in unique(fcst_tbl_filtered$Model_ID[fcst_tbl_filtered$Combo == combo])) {
#       # Filter data for the current combo and model_id
#       combo_model_data <- fcst_tbl_filtered %>%
#         dplyr::filter(Combo == combo, Model_ID == model_id)

#       # Calculate split index and separate data
#       n <- nrow(combo_model_data)
#       split_index <- ceiling(split_ratio * n)
#       print(split_index)
#       calibration_set <- combo_model_data[1:split_index, ]
#       cat("row count of calibration_set: ", nrow(calibration_set), "\n")
#       test_set <- combo_model_data[(split_index + 1):n, ]
#       cat("row count of test_set: ", nrow(test_set), "\n")

#       # Compute residuals and quantile values in the calibration set
#       residuals <- abs(calibration_set$Target - calibration_set$Forecast)
#       q_val_80 <- quantile(residuals, probs = conf_levels[1], na.rm = TRUE)
#       cat("Q_vals for Model_ID: ", model_id, " and Combo: ", combo, "\n")
#       cat("q_val_80: ", q_val_80, "\n")
#       q_val_95 <- quantile(residuals, probs = conf_levels[2], na.rm = TRUE)
#       cat("q_val_95: ", q_val_95, "\n")

#       # Store quantiles in the list using a unique key for each combo and model_id
#       key <- paste(combo, model_id, sep = "_")
#       quantiles_list[[key]] <- c(q_val_80, q_val_95)
#       cat("Quantiles for key: ", key, " are: ", quantiles_list[[key]], "\n")

#       # Calculate coverage
#       test_set <- test_set %>%
#         dplyr::mutate(
#           lo_80 = Forecast - q_val_80,
#           hi_80 = Forecast + q_val_80,
#           lo_95 = Forecast - q_val_95,
#           hi_95 = Forecast + q_val_95,
#           covered_80 = Target >= lo_80 & Target <= hi_80,
#           covered_95 = Target >= lo_95 & Target <= hi_95
#         )

#       # Store coverage rates
#       coverage_results[[key]] <- list(
#         coverage_80 = mean(test_set$covered_80, na.rm = TRUE),
#         coverage_95 = mean(test_set$covered_95, na.rm = TRUE)

#         )

#         # Create a ggplot for each Combo and Model_ID pair
#       p <- ggplot2::ggplot(test_set, ggplot2::aes(x = Date)) +
#         ggplot2::geom_line(ggplot2::aes(y = Target, color = "Actual"), size = 1) +
#         ggplot2::geom_line(ggplot2::aes(y = Forecast, color = "Forecast"), linetype = "dashed") +
#         ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_80, ymax = hi_80, fill = "80% Interval"), alpha = 0.4) +
#         ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_95, ymax = hi_95, fill = "95% Interval"), alpha = 0.2) +
#         ggplot2::scale_color_manual(values = c("Actual" = "blue", "Forecast" = "red")) +
#         ggplot2::scale_fill_manual(values = c("80% Interval" = "orange", "95% Interval" = "#ffbb00")) +
#         ggplot2::labs(title = paste("Prediction Intervals for Model ID:", model_id, " and Combo:", combo),
#             subtitle = paste("Coverage 80%:", format(mean(test_set$covered_80, na.rm = TRUE) * 100, nsmall = 2),
#                               "%, 95%:", format(mean(test_set$covered_95, na.rm = TRUE) * 100, nsmall = 2), "%"),
#             x = "Date", y = "Values") +
#         ggplot2::theme_minimal() +
#         ggplot2::guides(fill = ggplot2::guide_legend(title = "Prediction Intervals"),
#                         color = ggplot2::guide_legend(title = "Series"))

#       # Print or save the plot
#         print(p)
        

#       h <- ggplot2::ggplot(calibration_set, ggplot2::aes(x = residuals)) +
#         ggplot2::geom_histogram(binwidth = max(residuals) / 30, fill = "steelblue", color = "black") +  # Adjusted bin width
#         ggplot2::geom_vline(ggplot2::aes(xintercept = q_val_80, color = "80% Threshold"), linetype = "dashed", size = 1.5) +
#         ggplot2::geom_vline(ggplot2::aes(xintercept = q_val_95, color = "95% Threshold"), linetype = "dashed", size = 1.5) +
#         ggplot2::scale_color_manual(values = c("80% Threshold" = "orange", "95% Threshold" = "#ff0000")) +
#         ggplot2::labs(title = paste("Histogram of Residuals for Model ID:", model_id, " and Combo:", combo),
#                       x = "Residuals", y = "Count") +
#         ggplot2::theme_minimal() +
#         ggplot2::guides(color = ggplot2::guide_legend(title = "Thresholds"))  # Add legend for the thresholds

#       # Print histogram
#       print(h)


#     }


#     # p <- ggplot2::ggplot(test_set, ggplot2::aes(x = Date, y = Target)) +
#     #   ggplot2::geom_line(color = "blue", size = 1) +
#     #   ggplot2::geom_line(ggplot2::aes(y = Forecast), color = "red", linetype = "dashed") +
#     #   ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_80, ymax = hi_80), fill = "orange", alpha = 0.4, inherit.aes = FALSE) +
#     #   ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_95, ymax = hi_95), fill = "yellow", alpha = 0.2, inherit.aes = FALSE) +
#     #   ggplot2::labs(title = paste("Prediction Intervals for Model ID:", model_id, "Combo:", combo),
#     #        subtitle = paste("Coverage 80%:", format(coverage_results[[key]]$coverage_80 * 100, nsmall = 2),
#     #                         "%, 95%:", format(coverage_results[[key]]$coverage_95 * 100, nsmall = 2), "%"),
#     #        x = "Date", y = "Values") +
#     #   ggplot2::theme_minimal()

#     # # Print or save the plot
#     # print(p) 
    


#   }

#   # Apply quantiles and coverages to calculate prediction intervals
#   fcst_tbl <- fcst_tbl %>%
#     dplyr::rowwise() %>%
#     dplyr::mutate(
#       key = paste(Combo, Model_ID, sep = "_"),
#       lo_80 = Forecast - quantiles_list[[key]][1],
#       hi_80 = Forecast + quantiles_list[[key]][1],
#       lo_95 = Forecast - quantiles_list[[key]][2],
#       hi_95 = Forecast + quantiles_list[[key]][2],
#       coverage_80 = coverage_results[[key]]$coverage_80,
#       coverage_95 = coverage_results[[key]]$coverage_95
#     ) %>%
#     dplyr::select(-key)
 
# # Print or view coverage results


#   # Print coverage results
#   for (key in names(coverage_results)) {
#     cat("-------------------------------------\n")
#     cat("Coverage for", key, "\n")
#     cat("-------------------------------------\n")
#     cat((sprintf("Coverage for 80%% interval: %.2f%%\n",coverage_results[[key]]$coverage_80 * 100)))
#     cat((sprintf("Coverage for 95%% interval: %.2f%%\n",coverage_results[[key]]$coverage_95 * 100)))
#     cat("=====================================\n")
#   }

# # Z SCORE TESTING=====================
#   # Calculate the split index

# cat("\n=====================Z SCORE TESTING=====================\n")
#   # Loop over each combination of Combo and Model_ID
#   for (combo in unique(fcst_tbl_filtered$Combo)) {
#     for (model_id in unique(fcst_tbl_filtered$Model_ID[fcst_tbl_filtered$Combo == combo])) {
#       # Filter data for the current combo and model_id
#       combo_model_data <- fcst_tbl_filtered %>%
#         dplyr::filter(Combo == combo, Model_ID == model_id)
 
#       # Split data into calibration and test sets
#       n <- nrow(combo_model_data)
#       split_index <- ceiling(split_ratio * n)


#       calibration_set <- combo_model_data[1:split_index, ]
#       test_set <- combo_model_data[(split_index + 1):n, ]



#     #   # Print to check if there are matching IDs before filtering
#     # cat("Before filtering, nrow(combo_model_data): ", nrow(combo_model_data), "\n")
#     # cat("Unique Train_Test_IDs in combo_model_data: ", unique(combo_model_data$Train_Test_ID), "\n")
#     # cat("Back test IDs: ", back_test_ids, "\n")

#       # Filter step... we will use a "calibration" set... previously all test data was used, but this led to overfitting in testing..
#       prediction_interval_tbl <- calibration_set %>%
#           dplyr::filter(Train_Test_ID %in% back_test_ids) %>%
#           dplyr::mutate(Residual = Target - Forecast) %>%
#           dplyr::group_by(Combo, Model_ID) %>%
#           dplyr::summarise(Residual_Std_Dev = sd(Residual, na.rm = TRUE)) %>%
#           dplyr::ungroup()

# # Check after filtering
#         # cat("After filtering, nrow(prediction_interval_tbl): ", nrow(prediction_interval_tbl), "\n")


#       # print(prediction_interval_tbl)

#         fcst_tbl_z_score <- test_set %>%
#         dplyr::left_join(prediction_interval_tbl,
#           by = c("Model_ID", "Combo")
#         ) %>%
#         dplyr::mutate(
#           lo_80 = Forecast - (1.28 * Residual_Std_Dev), 
#           lo_95 = Forecast - (1.96 * Residual_Std_Dev), 
#           hi_80 = Forecast + (1.28 * Residual_Std_Dev), 
#           hi_95 = Forecast + (1.96 * Residual_Std_Dev),
#           coverage_80_z = Target >= lo_80 & Target <= hi_80,
#           coverage_95_z = Target >= lo_95 & Target <= hi_95
#         ) %>%
#         dplyr::select(-Residual_Std_Dev)
#         # print(fcst_tbl_z_score)
#         cat("Z Score CI estimator for ",paste(combo, model_id, sep = "_"), "\n")
#         cat("80: ", (1.28 * prediction_interval_tbl$Residual_Std_Dev), "\n")
#         cat("95: ", (1.96 * prediction_interval_tbl$Residual_Std_Dev), "\n")
#         cat("\n")
#         #fcst_tbl_z_score filtered by what is in test_set 
        

#         coverage_80_z <- mean(fcst_tbl_z_score$coverage_80_z, na.rm = TRUE)
#         coverage_95_z <- mean(fcst_tbl_z_score$coverage_95_z, na.rm = TRUE)

#       # Print results directly within the loop
      
#       # cat(sprintf("Combo: %s, Model ID: %s\n", combo, model_id))
#       #combime the combo and model id, having it be combo_model_id
#       cat("-------------------------------------\n")
#       cat("Coverage for ",paste(combo, model_id, sep = "_"), "\n")

#       cat("-------------------------------------\n")
#       cat(sprintf("Coverage for 80%% interval: %.2f%%\n", coverage_80_z * 100))
#       cat(sprintf("Coverage for 95%% interval: %.2f%%\n", coverage_95_z * 100))
#       cat("=====================================\n")
      
#     }
#   }
#   cat("_________________________________________________")


# # END Z SCORE TESTING=====================


    
    
#     # View(fcst_tbl)
#     # # Merge these prediction intervals back to the original dataset, ensuring all rows are kept
#     # final_tbl <- fcst_tbl_ordered %>%
#     #     dplyr::left_join(fcst_tbl %>% dplyr::select(Combo, Model_ID, Date, Train_Test_ID, lo_80, hi_80, lo_95, hi_95),
#     #                      by = c("Combo", "Model_ID", "Date", "Train_Test_ID"))

#     return(fcst_tbl)
# }

create_prediction_intervals <- function(fcst_tbl, train_test_split, conf_levels = c(0.80, 0.95), split_ratio = 0.8) {
  # Extract the Train_Test_IDs for the Back_Test run type
  back_test_ids <- train_test_split %>%
    dplyr::filter(Run_Type == "Back_Test") %>%
    dplyr::pull(Train_Test_ID)

  # Filter and order forecast table by Date
  fcst_tbl_filtered <- fcst_tbl %>%
    dplyr::filter(Train_Test_ID %in% back_test_ids) %>%
    dplyr::arrange(Date)

  # Initialize lists to store results
  quantiles_list <- list()
  coverage_results <- list()
  z_score_results <- list()

  cat("\n=====================PREDICTION INTERVAL TESTING=====================\n")

  for (combo in unique(fcst_tbl_filtered$Combo)) {
    for (model_id in unique(fcst_tbl_filtered$Model_ID[fcst_tbl_filtered$Combo == combo])) {
      # Filter data for the current combo and model_id
      combo_model_data <- fcst_tbl_filtered %>%
        dplyr::filter(Combo == combo, Model_ID == model_id)

      # Calculate split index and separate data
      n <- nrow(combo_model_data)
      split_index <- ceiling(split_ratio * n)
      calibration_set <- combo_model_data[1:split_index, ]
      test_set <- combo_model_data[(split_index + 1):n, ]

      # Conformal Prediction
      residuals <- abs(calibration_set$Target - calibration_set$Forecast)
      q_vals <- sapply(conf_levels, function(cl) quantile(residuals, probs = cl, na.rm = TRUE))
      #print(q_vals)
      cat("Q_vals for Model_ID: ", model_id, " and Combo: ", combo, "\n")
      cat("q_val_80: ", q_vals[1], "\n")
      cat("q_val_95: ", q_vals[2], "\n")
      cat("=====================================\n")

      # Z-Score Method
      z_scores <- c(qnorm((1 + conf_levels[1]) / 2), qnorm((1 + conf_levels[2]) / 2))
      residual_std_dev <- sd(calibration_set$Target - calibration_set$Forecast, na.rm = TRUE)
      z_vals <- z_scores * residual_std_dev
      cat("Z-Scores for Model_ID: ", model_id, " and Combo: ", combo, "\n")
      cat("z_val_80: ", z_vals[1], "\n")
      cat("z_val_95: ", z_vals[2], "\n")

      # Store results
      key <- paste(combo, model_id, sep = "_")
      quantiles_list[[key]] <- q_vals
      z_score_results[[key]] <- z_vals

      # Calculate coverage for both methods
      test_set <- test_set %>%
        dplyr::mutate(
          lo_80_conf = Forecast - q_vals[1],
          hi_80_conf = Forecast + q_vals[1],
          lo_95_conf = Forecast - q_vals[2],
          hi_95_conf = Forecast + q_vals[2],
          lo_80_z = Forecast - z_vals[1],
          hi_80_z = Forecast + z_vals[1],
          lo_95_z = Forecast - z_vals[2],
          hi_95_z = Forecast + z_vals[2],
          covered_80_conf = Target >= lo_80_conf & Target <= hi_80_conf,
          covered_95_conf = Target >= lo_95_conf & Target <= hi_95_conf,
          covered_80_z = Target >= lo_80_z & Target <= hi_80_z,
          covered_95_z = Target >= lo_95_z & Target <= hi_95_z
        )

      coverage_results[[key]] <- list(
        conf_80 = mean(test_set$covered_80_conf, na.rm = TRUE),
        conf_95 = mean(test_set$covered_95_conf, na.rm = TRUE),
        z_80 = mean(test_set$covered_80_z, na.rm = TRUE),
        z_95 = mean(test_set$covered_95_z, na.rm = TRUE)
      )

      # Create and print plots
      p <- ggplot2::ggplot(test_set, ggplot2::aes(x = Date)) +
        ggplot2::geom_line(ggplot2::aes(y = Target, color = "Actual"), size = 1) +
        ggplot2::geom_line(ggplot2::aes(y = Forecast, color = "Forecast"), linetype = "dashed") +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_80_conf, ymax = hi_80_conf, fill = "80% Conf"), alpha = 0.3) +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_95_conf, ymax = hi_95_conf, fill = "95% Conf"), alpha = 0.2) +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_80_z, ymax = hi_80_z, fill = "80% Z"), alpha = 0.3) +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lo_95_z, ymax = hi_95_z, fill = "95% Z"), alpha = 0.2) +
        ggplot2::scale_color_manual(values = c("Actual" = "blue", "Forecast" = "red")) +
        ggplot2::scale_fill_manual(values = c("80% Conf" = "orange", "95% Conf" = "#ffbb00", "80% Z" = "green", "95% Z" = "lightgreen")) +
        ggplot2::labs(title = paste("Prediction Intervals for Model ID:", model_id, "and Combo:", combo),
                      subtitle = paste("Conformal Coverage: 80%:", format(coverage_results[[key]]$conf_80 * 100, nsmall = 2),
                                       "%, 95%:", format(coverage_results[[key]]$conf_95 * 100, nsmall = 2), "%\n",
                                       "Z-Score Coverage: 80%:", format(coverage_results[[key]]$z_80 * 100, nsmall = 2),
                                       "%, 95%:", format(coverage_results[[key]]$z_95 * 100, nsmall = 2), "%"),
                      x = "Date", y = "Values") +
        ggplot2::theme_minimal() +
        ggplot2::guides(fill = ggplot2::guide_legend(title = "Prediction Intervals"),
                        color = ggplot2::guide_legend(title = "Series"))

      print(p)
      #save the plot
      ggplot2::ggsave(paste0("plots/prediction_intervals_", key, ".png"), plot = p, width = 10, height = 6, dpi = 300)

    }

    # Create and print histogram plot
      h <- ggplot2::ggplot(calibration_set, ggplot2::aes(x = abs(Target - Forecast))) +
        ggplot2::geom_histogram(binwidth = max(abs(calibration_set$Target - calibration_set$Forecast), na.rm = TRUE) / 30, 
                                fill = "steelblue", color = "black") +
        ggplot2::geom_vline(ggplot2::aes(xintercept = q_vals[1], color = "80% Threshold"), 
                            linetype = "dashed", size = 1.5) +
        ggplot2::geom_vline(ggplot2::aes(xintercept = q_vals[2], color = "95% Threshold"), 
                            linetype = "dashed", size = 1.5) +
        ggplot2::geom_vline(ggplot2::aes(xintercept = z_vals[1], color = "80% Z-Score"), 
                            linetype = "dotted", size = 1.5) +
        ggplot2::geom_vline(ggplot2::aes(xintercept = z_vals[2], color = "95% Z-Score"), 
                            linetype = "dotted", size = 1.5) +
        ggplot2::scale_color_manual(values = c("80% Threshold" = "orange", "95% Threshold" = "red",
                                               "80% Z-Score" = "green", "95% Z-Score" = "blue")) +
        ggplot2::labs(title = paste("Histogram of Residuals for Model ID:", model_id, "and Combo:", combo),
                      x = "Absolute Residuals", y = "Count") +
        ggplot2::theme_minimal() +
        ggplot2::guides(color = ggplot2::guide_legend(title = "Thresholds"))

      print(h)

      #save the plot
      ggplot2::ggsave(paste0("plots/histogram_residuals_", key, ".png"), plot = h, width = 10, height = 6, dpi = 300)
  }

  # Print coverage results
  cat("\n=======================COVERAGE RESULTS==========================\n")
  for (key in names(coverage_results)) {
    cat("-------------------------------------\n")
    cat("Coverage for", key, "\n")
    cat("-------------------------------------\n")
    cat(sprintf("Conformal 80%% interval: %.2f%%\n", coverage_results[[key]]$conf_80 * 100))
    cat(sprintf("Conformal 95%% interval: %.2f%%\n", coverage_results[[key]]$conf_95 * 100))
    cat(sprintf("Z-Score 80%% interval: %.2f%%\n", coverage_results[[key]]$z_80 * 100))
    cat(sprintf("Z-Score 95%% interval: %.2f%%\n", coverage_results[[key]]$z_95 * 100))
    cat("=====================================\n")
  }

  # Apply best method to full dataset
  fcst_tbl <- fcst_tbl %>%
    dplyr::rowwise() %>%
    dplyr::mutate(
      key = paste(Combo, Model_ID, sep = "_"),
      lo_80 = Forecast - ifelse(coverage_results[[key]]$z_80 > coverage_results[[key]]$conf_80, 
                                z_score_results[[key]][1], quantiles_list[[key]][1]),
      hi_80 = Forecast + ifelse(coverage_results[[key]]$z_80 > coverage_results[[key]]$conf_80, 
                                z_score_results[[key]][1], quantiles_list[[key]][1]),
      lo_95 = Forecast - ifelse(coverage_results[[key]]$z_95 > coverage_results[[key]]$conf_95, 
                                z_score_results[[key]][2], quantiles_list[[key]][2]),
      hi_95 = Forecast + ifelse(coverage_results[[key]]$z_95 > coverage_results[[key]]$conf_95, 
                                z_score_results[[key]][2], quantiles_list[[key]][2]),
      method_80 = ifelse(coverage_results[[key]]$z_80 > coverage_results[[key]]$conf_80, "Z-Score", "Conformal"),
      method_95 = ifelse(coverage_results[[key]]$z_95 > coverage_results[[key]]$conf_95, "Z-Score", "Conformal"),
      coverage_80 = ifelse(coverage_results[[key]]$z_80 > coverage_results[[key]]$conf_80, 
                           coverage_results[[key]]$z_80, coverage_results[[key]]$conf_80),
      coverage_95 = ifelse(coverage_results[[key]]$z_95 > coverage_results[[key]]$conf_95,
                           coverage_results[[key]]$z_95, coverage_results[[key]]$conf_95),
    ) %>%
    dplyr::select(-key)

    View(fcst_tbl)

  return(fcst_tbl)
}
#' Convert weekly forecast down to daily
#'
#' @param fcst_tbl forecast table to use to create prediction intervals
#' @param date_type date type
#' @param weekly_to_daily if weekly forecast should be converted to daily
#'
#' @return data frame with final forecasts
#' @noRd
convert_weekly_to_daily <- function(fcst_tbl,
                                    date_type,
                                    weekly_to_daily) {
  if (date_type == "week" & weekly_to_daily) { # allocate from weekly to daily

    final_tbl <- fcst_tbl %>%
      dplyr::group_by(
        Combo_ID, Model_ID, Model_Name, Model_Type, Recipe_ID,
        Train_Test_ID, Hyperparameter_ID, Best_Model, Combo, Horizon
      ) %>%
      dplyr::group_split() %>%
      purrr::map(.f = function(df) {
        daily_tbl <- df %>%
          dplyr::mutate(Date_Day = Date) %>%
          timetk::pad_by_time(Date_Day, .by = "day", .pad_value = NA, .end_date = max(df$Date) + 6) %>%
          tidyr::fill(tidyr::everything(), .direction = "down") %>%
          dplyr::mutate(
            Target = Target / 7,
            Forecast = Forecast / 7,
            lo_95 = lo_95 / 7,
            lo_80 = lo_80 / 7,
            hi_80 = hi_80 / 7,
            hi_95 = hi_95 / 7
          ) %>%
          dplyr::select(
            Combo_ID, Model_ID, Model_Name, Model_Type, Recipe_ID, Train_Test_ID, Hyperparameter_ID,
            Best_Model, Combo, Horizon, Date, Date_Day, Target, Forecast, lo_95, lo_80, hi_80, hi_95
          )

        return(daily_tbl)
      }) %>%
      dplyr::bind_rows()
  } else {
    final_tbl <- fcst_tbl %>%
      dplyr::select(
        Combo_ID, Model_ID, Model_Name, Model_Type, Recipe_ID, Train_Test_ID, Hyperparameter_ID,
        Best_Model, Combo, Horizon, Date, Target, Forecast, lo_95, lo_80, hi_80, hi_95
      )
  }

  return(final_tbl)
}

#' Check if there is a best model column and remove it
#'
#' @param df data frame
#'
#' @return data frame with no best model column
#' @noRd
remove_best_model <- function(df) {
  if ("Best_Model" %in% names(df)) {
    df <- df %>% dplyr::select(-Best_Model)
  }
  return(df)
}
