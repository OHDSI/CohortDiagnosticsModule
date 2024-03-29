# Copyright 2024 Observational Health Data Sciences and Informatics
#
# This file is part of CohortDiagnosticsModule
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Adding library references that are required for Strategus
library(CohortGenerator)
library(DatabaseConnector)
library(keyring)
library(ParallelLogger)
library(SqlRender)

# Adding RSQLite so that we can test modules with Eunomia
library(RSQLite)

# Module methods -------------------------
execute <- function(jobContext) {
  checkmate::assert_list(x = jobContext)
  if (is.null(jobContext$settings)) {
    stop("Analysis settings not found in job context")
  }
  if (is.null(jobContext$sharedResources)) {
    stop("Shared resources not found in job context")
  }
  if (is.null(jobContext$moduleExecutionSettings)) {
    stop("Execution settings not found in job context")
  }

  message("Creating cohort definition set from job context")
  cohortDefinitionSet <- createCohortDefinitionSetFromJobContext(
    sharedResources = jobContext$sharedResources,
    settings = jobContext$settings
  )

  message("Executing cohort diagnostics")
  exportFolder <- jobContext$moduleExecutionSettings$resultsSubFolder
  args <- jobContext$settings
  args$cohortDefinitionSet <- cohortDefinitionSet
  args$exportFolder <- exportFolder
  args$databaseId <- jobContext$moduleExecutionSettings$databaseId
  args$connectionDetails <- jobContext$moduleExecutionSettings$connectionDetails
  args$cdmDatabaseSchema <- jobContext$moduleExecutionSettings$cdmDatabaseSchema
  args$cohortDatabaseSchema <- jobContext$moduleExecutionSettings$workDatabaseSchema
  args$cohortTableNames <- jobContext$moduleExecutionSettings$cohortTableNames
  args$incrementalFolder <- jobContext$moduleExecutionSettings$workSubFolder
  args$minCellCount <- jobContext$moduleExecutionSettings$minCellCount
  args$cohortIds <- jobContext$moduleExecutionSettings$cohortIds
  do.call(CohortDiagnostics::executeDiagnostics, args)

  unlink(file.path(exportFolder, sprintf("Results_%s.zip", jobContext$moduleExecutionSettings$databaseId)))

  moduleInfo <- ParallelLogger::loadSettingsFromJson("MetaData.json")

  # Prefer to use this approach once the bug mentioned below is resolved
  # resultsDataModel <- CohortGenerator::readCsv(
  #   file = system.file("settings", "resultsDataModelSpecification.csv", package = "CohortDiagnostics"),
  #   warnOnCaseMismatch = FALSE
  # )
  # AGS: Work-around until we patch the "empty_is_Na" column in the rdms spec
  resultsDataModel <- readr::read_csv(
    file = system.file("settings", "resultsDataModelSpecification.csv", package = "CohortDiagnostics"),
    show_col_types = FALSE
  )
  colnames(resultsDataModel) <- SqlRender::snakeCaseToCamelCase(tolower(colnames(resultsDataModel)))
  resultsDataModel <- resultsDataModel[file.exists(file.path(exportFolder, paste0(resultsDataModel$tableName, ".csv"))), ]
  newTableNames <- paste0(moduleInfo$TablePrefix, resultsDataModel$tableName)
  file.rename(
    file.path(exportFolder, paste0(unique(resultsDataModel$tableName), ".csv")),
    file.path(exportFolder, paste0(unique(newTableNames), ".csv"))
  )
  resultsDataModel$tableName <- newTableNames
  CohortGenerator::writeCsv(
    x = resultsDataModel,
    file.path(exportFolder, "resultsDataModelSpecification.csv"),
    warnOnFileNameCaseMismatch = FALSE
  )
}

# Private methods -------------------------
getSharedResourceByClassName <- function(sharedResources, className) {
  returnVal <- NULL
  for (i in 1:length(sharedResources)) {
    if (className %in% class(sharedResources[[i]])) {
      returnVal <- sharedResources[[i]]
      break
    }
  }
  invisible(returnVal)
}
.getCohortDefinitionSetFromSharedResource <- function(cohortDefinitionSharedResource, settings) {
  cohortDefinitions <- cohortDefinitionSharedResource$cohortDefinitions
  if (length(cohortDefinitions) <= 0) {
    stop("No cohort definitions found")
  }
  cohortDefinitionSet <- CohortGenerator::createEmptyCohortDefinitionSet()
  for (i in 1:length(cohortDefinitions)) {
    cohortJson <- cohortDefinitions[[i]]$cohortDefinition
    cohortExpression <- CirceR::cohortExpressionFromJson(cohortJson)
    cohortSql <- CirceR::buildCohortQuery(cohortExpression, options = CirceR::createGenerateOptions(generateStats = FALSE))
    cohortDefinitionSet <- rbind(cohortDefinitionSet, data.frame(
      cohortId = as.numeric(cohortDefinitions[[i]]$cohortId),
      cohortName = cohortDefinitions[[i]]$cohortName,
      sql = cohortSql,
      json = cohortJson,
      stringsAsFactors = FALSE
    ))
  }

  if (length(cohortDefinitionSharedResource$subsetDefs)) {
    subsetDefinitions <- lapply(cohortDefinitionSharedResource$subsetDefs, CohortGenerator::CohortSubsetDefinition$new)
    for (subsetDef in subsetDefinitions) {
      ind <- which(sapply(cohortDefinitionSharedResource$cohortSubsets, function(y) subsetDef$definitionId %in% y$subsetId))
      targetCohortIds <- unlist(lapply(cohortDefinitionSharedResource$cohortSubsets[ind], function(y) y$targetCohortId))
      cohortDefinitionSet <- CohortGenerator::addCohortSubsetDefinition(
        cohortDefinitionSet = cohortDefinitionSet,
        cohortSubsetDefintion = subsetDef,
        targetCohortIds = targetCohortIds
      )
    }
  }

  return(cohortDefinitionSet)
}

createCohortDefinitionSetFromJobContext <- function(sharedResources, settings) {
  cohortDefinitions <- list()
  if (length(sharedResources) <= 0) {
    stop("No shared resources found")
  }
  cohortDefinitionSharedResource <- getSharedResourceByClassName(
    sharedResources = sharedResources,
    class = "CohortDefinitionSharedResources"
  )
  if (is.null(cohortDefinitionSharedResource)) {
    stop("Cohort definition shared resource not found!")
  }

  if ((is.null(cohortDefinitionSharedResource$subsetDefs) && !is.null(cohortDefinitionSharedResource$cohortSubsets)) ||
    (!is.null(cohortDefinitionSharedResource$subsetDefs) && is.null(cohortDefinitionSharedResource$cohortSubsets))) {
    stop("Cohort subset functionality requires specifying cohort subset definition & cohort subset identifiers.")
  }

  cohortDefinitionSet <- .getCohortDefinitionSetFromSharedResource(
    cohortDefinitionSharedResource = cohortDefinitionSharedResource,
    settings = settings
  )
  return(cohortDefinitionSet)
}

getModuleInfo <- function() {
  checkmate::assert_file_exists("MetaData.json")
  return(ParallelLogger::loadSettingsFromJson("MetaData.json"))
}


uploadResultsCallback <- function(jobContext) {
  connectionDetails <- jobContext$moduleExecutionSettings$resultsConnectionDetails
  moduleInfo <- ParallelLogger::loadSettingsFromJson("MetaData.json")
  tablePrefix <- moduleInfo$TablePrefix
  schema <- jobContext$moduleExecutionSettings$resultsDatabaseSchema
  zipFileName <- sprintf("Results_%s.zip", jobContext$moduleExecutionSettings$databaseId)
  CohortDiagnostics::uploadResults(
    connectionDetails = connectionDetails,
    schema = schema,
    tablePrefix = tablePrefix,
    zipFileName = zipFileName
  )
}

createDataModelSchema <- function(jobContext) {
  connectionDetails <- jobContext$moduleExecutionSettings$resultsConnectionDetails
  moduleInfo <- ParallelLogger::loadSettingsFromJson("MetaData.json")
  tablePrefix <- moduleInfo$TablePrefix
  databaseSchema <- jobContext$moduleExecutionSettings$resultsDatabaseSchema
  # Workaround for issue https://github.com/tidyverse/vroom/issues/519:
  readr::local_edition(1)
  CohortDiagnostics::createResultsDataModel(connectionDetails = connectionDetails, databaseSchema = databaseSchema, tablePrefix = tablePrefix)
}
