# This function converts the contents in a .tsf file into a tsibble or a dataframe and returns it along with other meta-data of the dataset: frequency, horizon, whether the dataset contains missing values and whether the series have equal lengths
#
# Parameters
# file - .tsf file path
# value_column_name - Any name that is preferred to have as the name of the column containing series values in the returning tsibble
# key - The name of the attribute that should be used as the key when creating the tsibble. If doesn't provide, a data frame will be returned instead of a tsibble
# index - The name of the time attribute that should be used as the index when creating the tsibble. If doesn't provide, it will search for a valid index. When no valid index found, a data frame will be returned instead of a tsibble
convert_tsf_to_tsibble <-   function(file, value_column_name = "series_value", key = NULL, index = NULL){
  # Extend these frequency lists as required
  LOW_FREQUENCIES <- c("4_seconds", "minutely", "10_minutes", "15_minutes", "half_hourly", "hourly")
  LOW_FREQ_VALS <- c("4 sec", "1 min", "10 min", "15 min", "30 min", "1 hour")
  HIGH_FREQUENCIES <- c("daily", "weekly", "monthly", "quarterly", "yearly")
  HIGH_FREQ_VALS <- c("1 day", "1 week", "1 month", "3 months", "1 year")
  FREQUENCIES <- c(LOW_FREQUENCIES, HIGH_FREQUENCIES)
  FREQ_VALS <- c(LOW_FREQ_VALS, HIGH_FREQ_VALS)


  # Create a hashmap containing possible frequency key-value pairs
  FREQ_MAP <- list()

  for(f in seq_along(FREQUENCIES))
    FREQ_MAP[[FREQUENCIES[f]]] <- FREQ_VALS[f]

  if(is.character(file)) {
    file <- file(file, "r")
    on.exit(close(file))
  }
  if(!inherits(file, "connection"))
    stop("Argument 'file' must be a character string or connection.")
  if(!isOpen(file)) {
    open(file, "r")
    on.exit(close(file))
  }

  # Read meta-data
  col_names <- NULL
  col_types <- NULL
  frequency <- NULL
  forecast_horizon <- NULL
  contain_missing_values <- NULL
  contain_equal_length <- NULL
  index_var <- NULL

  line <- readLines(file, n = 1) #n is no: of lines to read

  while(length(line) && regexpr('^[[:space:]]*@data', line, perl = TRUE) == -1) { #Until read @data, run this loop (-1 indicate no match with the regular expression yet)

    if(regexpr('^[[:space:]]*@', line, perl = TRUE) > 0) { #This condition will be true for lines starting with @

      con <- textConnection(line)
      line <- scan(con, character(), quiet = TRUE) #Creating a vector containing the words in a line (ex: "@attribute" "series_name" "string")
      close(con)

      if(line[1] == "@attribute"){
        if(length(line) != 3)  #Attributes have both name and type
          stop("Invalid meta-data specification.")

        if(is.null(index) & line[3] == "date")
          index_var <- line[2]

        col_names <- c(col_names, line[2])
        col_types <- c(col_types, line[3])
      }else{
        if(length(line) != 2) #Other meta-data have only values
          stop("Invalid meta-data specification.")

        if(line[1] == "@frequency")
          frequency <- line[2]
        else if(line[1] == "@horizon")
          forecast_horizon <- as.numeric(line[2])
        else if(line[1] == "@missing")
          contain_missing_values <- as.logical(line[2])
        else if(line[1] == "@equallength")
          contain_equal_length <- as.logical(line[2])
      }
    }
    line <- readLines(file, n = 1)
  }

  if(length(line) == 0)
    stop("Missing data section.")
  if(is.null(col_names))
    stop("Missing attribute section.")

  line <- readLines(file, n = 1)

  if(length(line) == 0)
    stop("Missing series information under data section.")

  for(col in col_names)
    assign(col, NULL)

  values <- NULL
  row_count <- 0

  # Get data
  while(length(line) != 0){
    full_info <- strsplit(line, ":")[[1]]

    if(length(full_info) != length(col_names)+1)
      stop("Missing attributes/values in series.")

    series <- strsplit(utils::tail(full_info, 1), ",")[[1]]
    series[which(series == "?")] <- NA
    series <- as.numeric(series)

    if(all(is.na(series)))
      stop("All series values are missing. A given series should contains a set of comma separated numeric values. At least one numeric value should be there in a series.")

    values <- c(values, series)
    row_count <- row_count + length(series)

    attributes <- utils::head(full_info, length(full_info)-1)

    for(col in seq_along(col_names)){

      att <- eval(parse(text=col_names[col]))

      #This format supports 3 attribute types: string, numeric and date
      if(col_types[col] == "date"){
        if(is.null(frequency))
          stop("Frequency is missing.")
        else{
          if(frequency %in% LOW_FREQUENCIES)
            start_time <- as.POSIXct(attributes[col], format = "%Y-%m-%d %H-%M-%S", tz = "UTC")
          else if(frequency %in% HIGH_FREQUENCIES)
            start_time <- as.Date(attributes[col], format = "%Y-%m-%d %H-%M-%S")
          else
            stop("Invalid frequency.")

          if(is.na(start_time))
            stop("Incorrect timestamp format. Specify your timestamps as YYYY-mm-dd HH-MM-SS")
        }

        timestamps <- seq(start_time, length.out = length(series), by = FREQ_MAP[[frequency]])

        if(is.null(att))
          att <- timestamps
        else
          att[(length(att) + 1) : ((length(att) + length(timestamps)))] <- timestamps
      }else{
        if(col_types[col] == "numeric")
          attributes[col] <- as.numeric(attributes[col])
        else if(col_types[col] == "string")
          attributes[col] <- as.character(attributes[col])
        else
          stop("Invalid attribute type.")

        if(is.na(attributes[col]))
          stop("Invalid attribute values.")

        att <- append(att, rep(attributes[col], length(series)))
      }
      assign(col_names[col], att)
    }

    line <- readLines(file, n = 1)
  }

  data <- as.data.frame(matrix(nrow = row_count, ncol = length(col_names) + 1))
  colnames(data) <- c(col_names, value_column_name)

  for(col in col_names)
    data[[col]] <- eval(parse(text = col))

  data[[value_column_name]] <- values

  if(!(is.null(key))){
    if(!(key %in% col_names))
      stop("Invalid key. Cannot convert data into tsibble format.")
    else{
      if(is.null(index)){
        if(is.null(index_var))
          cat("Index is not provided. No valid index found in data. Returning a dataframe.")
        else
          data <- tsibble:::build_tsibble(x = data, key = key, index = index_var, ordered = F)
      }else{
        if(!(index %in% col_names))
          stop("Invalid index Cannot convert data into tsibble format.")
        else
          data <- tsibble:::build_tsibble(x = data, key = key, index = index, ordered = F)
      }
    }
  }else{
    cat("Key is not provided. Returning a dataframe.")
  }

  list(data, frequency, forecast_horizon, contain_missing_values, contain_equal_length)
}


#' load M3 yearly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M3_yearly <- function(file = "G:/Mi unidad/data/m3_yearly_dataset.tsf") {
  loaded_data <- convert_tsf_to_tsibble(file, "series_value", "series_name", "start_timestamp")
  tsibble_data <- loaded_data[[1]]
  frequency <- loaded_data[[2]]
  forecast_horizon <- loaded_data[[3]]
  contain_missing_values <- loaded_data[[4]]
  contain_equal_length <- loaded_data[[5]]
  tsibble_data |> dplyr::mutate(start_timestamp = lubridate::year(start_timestamp)) -> tsibble_data
  names <- tsibble_data$series_name |> unique()
  S <- vector(mode = "list", length(names))
  for (ind in seq_along(names)) {
    s <- tsibble_data |> dplyr::filter(series_name == names[ind])
    training <- s |> utils::head(-forecast_horizon)
    test <- s |> utils::tail(forecast_horizon)
    training <- stats::ts(training$series_value, start = training$start_timestamp[1], frequency = 1)
    test <- stats::ts(test$series_value, start = test$start_timestamp[1], frequency = 1)
    S[[ind]] <- list(name = names[ind], training = training, test = test)
  }
  S
}

#' load M3 quarterly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M3_quarterly <- function(file = "G:/Mi unidad/data/m3_quarterly_dataset.tsf") {
  loaded_data <- convert_tsf_to_tsibble(file, "series_value", "series_name", "start_timestamp")
  tsibble_data <- loaded_data[[1]]
  frequency <- loaded_data[[2]]
  forecast_horizon <- loaded_data[[3]]
  contain_missing_values <- loaded_data[[4]]
  contain_equal_length <- loaded_data[[5]]
  tsibble_data |> dplyr::mutate(start_timestamp = tsibble::yearquarter(start_timestamp)) -> tsibble_data
  names <- tsibble_data$series_name |> unique()
  S <- vector(mode = "list", length(names))
  for (ind in seq_along(names)) {
    s <- tsibble_data |> dplyr::filter(series_name == names[ind])
    training <- s |> utils::head(-forecast_horizon)
    test <- s |> utils::tail(forecast_horizon)
    start <- c(lubridate::year(training$start_timestamp[1]), lubridate::quarter(training$start_timestamp[1]))
    training <- stats::ts(training$series_value, start = start, frequency = 4)
    start <- c(lubridate::year(test$start_timestamp[1]), lubridate::quarter(test$start_timestamp[1]))
    test <- stats::ts(test$series_value, start = start, frequency = 4)
    S[[ind]] <- list(name = names[ind], training = training, test = test)
  }
  S
}

#' load M3 monthly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M3_monthly <- function(file = "G:/Mi unidad/data/m3_monthly_dataset.tsf") {
  loaded_data <- convert_tsf_to_tsibble(file, "series_value", "series_name", "start_timestamp")
  tsibble_data <- loaded_data[[1]]
  frequency <- loaded_data[[2]]
  forecast_horizon <- loaded_data[[3]]
  contain_missing_values <- loaded_data[[4]]
  contain_equal_length <- loaded_data[[5]]
  tsibble_data |> dplyr::mutate(start_timestamp = tsibble::yearmonth(start_timestamp)) -> tsibble_data
  names <- tsibble_data$series_name |> unique()
  S <- vector(mode = "list", length(names))
  for (ind in seq_along(names)) {
    s <- tsibble_data |> dplyr::filter(series_name == names[ind])
    training <- s |> utils::head(-forecast_horizon)
    test <- s |> utils::tail(forecast_horizon)
    start <- c(lubridate::year(training$start_timestamp[1]), lubridate::month(training$start_timestamp[1]))
    training <- stats::ts(training$series_value, start = start, frequency = 12)
    start <- c(lubridate::year(test$start_timestamp[1]), lubridate::month(test$start_timestamp[1]))
    test <- stats::ts(test$series_value, start = start, frequency = 12)
    S[[ind]] <- list(name = names[ind], training = training, test = test)
  }
  S
}

#' load M4 quarterly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M4_quarterly <- function(file = "G:/Mi unidad/data/m4_quarterly_dataset.tsf") {
  f <- file(file, "r")
  line <- readLines(f, n = 1)
  while (line != "@data") {
    line <- readLines(f, n = 1)
  }
  line <- readLines(f, n = 1)
  S <- list()
  while (length(line) == 1) {
    l <- unlist(strsplit(line, split = ":"))
    name <- l[1]
    date <- as.Date(l[2], format = "%Y-%m-%d %H-%M-%S")
    yq <- tsibble::yearquarter(date)
    year <- lubridate::year(yq)
    quarter <- lubridate::quarter(yq)
    timeS <- as.numeric(unlist(strsplit(l[3], split = ",")))
    timeS <- stats::ts(timeS, start = c(year, quarter), frequency = 4)
    horizon <- 8
    training <- stats::window(timeS, end = stats::time(timeS)[length(timeS)-horizon])
    test <- stats::window(timeS, start = stats::time(timeS)[length(timeS)-horizon+1])
    line <- readLines(f, n = 1)
    S[[length(S)+1]] <- list(name = name, training = training, test = test)
  }
  close(f)
  S
}

#' load M4 monthly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M4_monthly <- function(file = "G:/Mi unidad/data/m4_monthly_dataset.tsf") {
  f <- file(file, "r")
  line <- readLines(f, n = 1)
  while (line != "@data") {
    line <- readLines(f, n = 1)
  }
  line <- readLines(f, n = 1)
  S <- list()
  while (length(line) == 1) {
    l <- unlist(strsplit(line, split = ":"))
    name <- l[1]
    date <- as.Date(l[2], format = "%Y-%m-%d %H-%M-%S")
    year <- lubridate::year(date)
    month <- lubridate::month(date)
    timeS <- as.numeric(unlist(strsplit(l[3], split = ",")))
    timeS <- stats::ts(timeS, start = c(year, month), frequency = 12)
    horizon <- 18
    training <- stats::window(timeS, end = stats::time(timeS)[length(timeS)-horizon])
    test <- stats::window(timeS, start = stats::time(timeS)[length(timeS)-horizon+1])
    line <- readLines(f, n = 1)
    S[[length(S)+1]] <- list(name = name, training = training, test = test)
  }
  close(f)
  S
}

#' load M4 yearly time series
#'
#' @param file The tsf file with the data
#'
#' @return A list with the time series in ts format
#' @export
#'
#' @examples
load_M4_yearly <- function(file = "G:/Mi unidad/data/m4_yearly_dataset.tsf") {
  f <- file(file, "r")
  line <- readLines(f, n = 1)
  while (line != "@data") {
    line <- readLines(f, n = 1)
  }
  line <- readLines(f, n = 1)
  S <- list()
  while (length(line) == 1) {
    l <- unlist(strsplit(line, split = ":"))
    name <- l[1]
    date <- as.Date(l[2], format = "%Y-%m-%d %H-%M-%S")
    year <- lubridate::year(date)
    timeS <- as.numeric(unlist(strsplit(l[3], split = ",")))
    timeS <- stats::ts(timeS, start = year, frequency = 1)
    horizon <- 6
    training <- stats::window(timeS, end = stats::time(timeS)[length(timeS)-horizon])
    test <- stats::window(timeS, start = stats::time(timeS)[length(timeS)-horizon+1])
    line <- readLines(f, n = 1)
    S[[length(S)+1]] <- list(name = name, training = training, test = test)
  }
  close(f)
  S
}
