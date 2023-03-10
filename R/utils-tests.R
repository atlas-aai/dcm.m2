#' Simulate attribute mastery profile
#'
#' Simulates the attribute mastery profile for an examinee
#'
#' @param theta A random number drawn from a standard normal distribution for
#' the proficiency of the examinee.
#' @param bk0 The association between attributes.
#' @param bk1 The base rate of mastery for the attribute.
#'
#' @noRd
profile_create <- function(theta, bk0, bk1) {
  purrr::map2_int(bk0, bk1,
                   function(x, y, theta) {
                     purrr::rbernoulli(n = 1, stats::pnorm(x * (theta - y)))
                   },
                   theta = theta) %>%
    rlang::set_names(glue::glue("att_{1:length(.)}")) %>%
    tibble::enframe() %>%
    tidyr::pivot_wider(names_from = .data$name, values_from = .data$value)
}


#' Check whether all values are zero
#'
#' Tests whether all values in a vector are equal to zero
#'
#' @param x A vector of numeric values.
#'
#' @noRd
all_zero <- function(x) {
  all(x == 0)
}

#' Repair variables names
#'
#' Repair the variable names in a tibble
#'
#' @param x A tibble
#'
#' @noRd
repair_names <- function(x) {
  stringr::str_replace_all(x, stringr::fixed("."), "__")
}

#' Simulate a data set
#'
#' Simulates the item response data for examinees
#'
#' @param sample_size The number of examinees in the simulated data set.
#' @param test_length The minimum number of items per attribute.
#' @param prevalence The base rate of mastery for the attribute.
#' @param discrimination The discrimination of the item.
#' @param association The association between the attributes.
#' @param attributes The number of assessed attributes.
#'
#' @noRd
generate_data <- function(sample_size, test_length, prevalence,
                          discrimination, association, attributes) {
  # generate mastery profiles -----
  resp_trait <- stats::rnorm(n = sample_size, mean = 0, sd = 1)
  bk0 <- c(association, stats::runif(n = attributes - 1L, min = 0, max = 2))
  bk1 <- c(prevalence, stats::runif(n = attributes - 1L, min = 0.2, max = 0.8))
  profiles <- purrr::map_dfr(resp_trait, profile_create, bk0 = bk0,
                             bk1 = bk1) %>%
    tibble::rowid_to_column(var = "resp_id")

  # generate Q-matrix -----
  all_combo <- rep(list(c(0L, 1L)), attributes) %>%
    rlang::set_names(glue::glue("att_{seq_len(attributes)}")) %>%
    expand.grid() %>%
    dplyr::mutate(total = rowSums(.)) %>%
    dplyr::select(.data$total, dplyr::everything()) %>%
    dplyr::arrange_at(dplyr::vars(.data$total,
                                  dplyr::desc(-dplyr::one_of("total")))) %>%
    dplyr::filter(dplyr::between(.data$total, 1, 2)) %>%
    dplyr::mutate(prob = dplyr::case_when(.data$total == 1 ~ 0.500,
                                          TRUE ~ 0.5 / (attributes - 1)))
  q_matrix <- purrr::map_dfr(
    seq_len(test_length),
    function(chunk, all_combo, att) {
      if (chunk %in% c(1, 2)) {
        ret_chk <- diag(x = 1L, nrow = att, ncol = att) %>%
          tibble::as_tibble(.name_repair = ~glue::glue("att_{1:att}"))
        return(ret_chk)
      }

      ret_chk <- purrr::map_dfr(
        glue::glue("att_{1:att}"),
        function(var, all_combo) {
          dplyr::filter(all_combo,
                        !!dplyr::sym(var) == 1) %>%
            dplyr::sample_n(size = 1, replace = FALSE,
                            weight = .data$prob)
        },
        all_combo = all_combo) %>%
        dplyr::select(dplyr::starts_with("att"))
      return(ret_chk)
    },
    all_combo = all_combo, att = attributes)

  # generate item parameters -----
  if(attributes == 1) {
    needed_params <-
      modelr::model_matrix(q_matrix, stats::as.formula(paste0("~ .^", 2))) %>%
      tibble::rowid_to_column(var = "item_id") %>%
      dplyr::select_if(~ !all_zero(.x)) %>%
      rlang::set_names(nm = vctrs::vec_as_names(names(.), repair = "universal",
                                                quiet = TRUE)) %>%
      dplyr::rename(intercept = .data$.Intercept.) %>%
      dplyr::rename_all(repair_names)
  } else {
    needed_params <-
      modelr::model_matrix(q_matrix, stats::as.formula(paste0("~ .^",
                                                              attributes))) %>%
      tibble::rowid_to_column(var = "item_id") %>%
      dplyr::select_if(~ !all_zero(.x)) %>%
      rlang::set_names(nm = vctrs::vec_as_names(names(.), repair = "universal",
                                                quiet = TRUE)) %>%
      dplyr::rename(intercept = .data$.Intercept.) %>%
      dplyr::rename_all(repair_names)
  }
  param_names <- colnames(needed_params)
  needed_params <- needed_params %>%
    tidyr::pivot_longer(cols = -.data$item_id, names_to = "param",
                        values_to = "valid") %>%
    dplyr::filter(.data$valid == 1)

  intercepts <- needed_params %>%
    dplyr::filter(.data$param == "intercept") %>%
    dplyr::mutate(prob = stats::runif(n = dplyr::n(), min = 0.1, max = 0.35),
                  value = logit(.data$prob)) %>%
    dplyr::select(.data$item_id, intercept = .data$value)

  effects <- needed_params %>%
    dplyr::filter(.data$param != "intercept") %>%
    tidyr::nest(item_params = -.data$item_id) %>%
    dplyr::mutate(params = purrr::map(item_params,
                        function(x, dis, att) {
                          if (nrow(x) == 1) {
                            effect <- x %>%
                              dplyr::mutate(value = stats::rnorm(1, mean = dis,
                                                                 sd = 0.25))
                          } else {
                            effect <- x %>%
                              dplyr::mutate(
                                mef = dplyr::case_when(
                                  !stringr::str_detect(.data$param, "__") ~
                                    truncnorm::rtruncnorm(dplyr::n(), a = 0,
                                                          mean = dis / 1.5,
                                                          sd = sqrt(1 / 36))
                                ),
                                int = dplyr::case_when(
                                  stringr::str_detect(.data$param, "__") ~
                                    truncnorm::rtruncnorm(dplyr::n(),
                                                          a = -1 * min(.data$mef,
                                                                       na.rm =
                                                                         TRUE),
                                                          mean = dis / 1.5,
                                                          sd = sqrt(1 / 36))
                                ),
                                value = dplyr::coalesce(.data$mef, .data$int)
                              ) %>%
                              dplyr::select(.data$param, .data$valid,
                                            .data$value)
                          }
                          ret_frame <- effect %>%
                            dplyr::select(.data$param, .data$value) %>%
                            tidyr::pivot_wider(names_from = .data$param,
                                               values_from = .data$value)
                          return(ret_frame)
                        },
                        dis = discrimination, att = attributes)) %>%
    dplyr::select(.data$item_id, .data$params) %>%
    tidyr::unnest(.data$params)

  item_params <- dplyr::full_join(intercepts, effects, by = "item_id") %>%
    dplyr::select({{param_names}})

  # generate response data -----
  if(attributes == 1) {
    resp_data <- profiles %>%
      dplyr::select(-.data$resp_id) %>%
      modelr::model_matrix(stats::as.formula(paste0("~ .^", 2))) %>%
      tibble::rowid_to_column(var = "resp_id") %>%
      dplyr::select_if(~ !all_zero(.x)) %>%
      rlang::set_names(nm = vctrs::vec_as_names(names(.), repair = "universal",
                                                quiet = TRUE)) %>%
      dplyr::rename(intercept = .data$.Intercept.) %>%
      dplyr::rename_all(repair_names) %>%
      tidyr::pivot_longer(cols = -.data$resp_id, names_to = "param",
                          values_to = "mastery") %>%
      dplyr::left_join(item_params %>%
                         tidyr::pivot_longer(cols = -.data$item_id,
                                             names_to = "param",
                                             values_to = "item_param"),
                by = "param") %>%
      dplyr::filter(!is.na(.data$item_param)) %>%
      dplyr::select(.data$resp_id, .data$item_id, .data$param, .data$mastery,
                    .data$item_param) %>%
      dplyr::arrange(.data$resp_id, .data$item_id) %>%
      dplyr::mutate(param_value = .data$mastery * .data$item_param) %>%
      dplyr::group_by(.data$resp_id, .data$item_id) %>%
      dplyr::summarize(log_odds = sum(.data$param_value), .groups = 'drop') %>%
      dplyr::ungroup() %>%
      dplyr::mutate(prob = purrr::map_dbl(.data$log_odds, inv_logit),
                    rand = stats::runif(dplyr::n(), min = 0, max = 1),
                    score = dplyr::case_when(.data$rand <= .data$prob ~ 1L,
                                             TRUE ~ 0L)) %>%
      dplyr::select(.data$resp_id, .data$item_id, .data$score)
  } else {
    resp_data <- profiles %>%
      dplyr::select(-.data$resp_id) %>%
      modelr::model_matrix(stats::as.formula(paste0("~ .^", attributes))) %>%
      tibble::rowid_to_column(var = "resp_id") %>%
      dplyr::select_if(~ !all_zero(.x)) %>%
      rlang::set_names(nm = vctrs::vec_as_names(names(.), repair = "universal",
                                                quiet = TRUE)) %>%
      dplyr::rename(intercept = .data$.Intercept.) %>%
      dplyr::rename_all(repair_names) %>%
      tidyr::pivot_longer(cols = -.data$resp_id, names_to = "param",
                          values_to = "mastery") %>%
      dplyr::left_join(item_params %>%
                       tidyr::pivot_longer(cols = -.data$item_id,
                                           names_to = "param",
                                           values_to = "item_param"),
                       by = "param") %>%
      dplyr::filter(!is.na(.data$item_param)) %>%
      dplyr::select(.data$resp_id, .data$item_id, .data$param, .data$mastery,
                    .data$item_param) %>%
      dplyr::arrange(.data$resp_id, .data$item_id) %>%
      dplyr::mutate(param_value = .data$mastery * .data$item_param) %>%
      dplyr::group_by(.data$resp_id, .data$item_id) %>%
      dplyr::summarize(log_odds = sum(.data$param_value), .groups = 'drop') %>%
      dplyr::ungroup() %>%
      dplyr::mutate(prob = purrr::map_dbl(.data$log_odds, inv_logit),
                    rand = stats::runif(dplyr::n(), min = 0, max = 1),
                    score = dplyr::case_when(.data$rand <= .data$prob ~ 1L,
                                             TRUE ~ 0L)) %>%
      dplyr::select(.data$resp_id, .data$item_id, .data$score)
  }

  # return generated data -----
  ret_list <- list(resp_profiles = profiles,
                   q_matrix = q_matrix,
                   item_params = item_params,
                   data = resp_data)
  return(ret_list)
}

#' Format a GDINA object as an lcdmr object
#'
#' @param gdina_mod A GDINA model object containing the estimated model.
#' @param n The sample size for the estimated model.
#' @param natt The number of assessed attributes.
#'
#' @return `ret_list` A list containing:
#' * `pxi`: The base rate of class membership
#' * `beta`: The estimated item parameters
#'
#' @noRd
format_gdina_as_lcdmr  <- function(gdina_mod, n, natt) {
  pxi <- gdina_mod$struc.parm

  beta <- gdina_mod$LC.prob %>%
    tibble::as_tibble()

  params <- att_profile(natt)

  colnames(beta) <- params

  ### Final List -----
  ret_list <- list(
    pxi = pxi,
    beta = beta
  )
  return(ret_list)
}
