# Copyright 2023 Observational Health Data Sciences and Informatics
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
  cohortDefinitionSet <- createCohortDefinitionSetFromJobContext(sharedResources = jobContext$sharedResources)

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
  file.rename(file.path(exportFolder, paste0(unique(resultsDataModel$tableName), ".csv")),
              file.path(exportFolder, paste0(unique(newTableNames), ".csv")))
  resultsDataModel$tableName <- newTableNames
  CohortGenerator::writeCsv(
    x = resultsDataModel, 
    file.path(exportFolder, "resultsDataModelSpecification.csv"),
    warnOnFileNameCaseMismatch = FALSE
  )
}

# Private methods -------------------------
createCohortDefinitionSetFromJobContext <- function(sharedResources) {
  cohortDefinitions <- list()
  if (length(sharedResources) <= 0) {
    stop("No shared resources found")
  }
  for (i in 1:length(sharedResources)) {
    if (which(class(sharedResources[[i]]) %in% "CohortDefinitionSharedResources") > 0) {
      cohortDefinitions <- sharedResources[[i]]$cohortDefinitions
      break;
    }
  }
  if (length(cohortDefinitions) <= 0) {
    stop("No cohort definitions found")
  }
  cohortDefinitionSet <- CohortGenerator::createEmptyCohortDefinitionSet()
  for (i in 1:length(cohortDefinitions)) {
    cohortJson <- cohortDefinitions[[i]]$cohortDefinition
    cohortExpression <- CirceR::cohortExpressionFromJson(cohortJson)
    cohortSql <- CirceR::buildCohortQuery(cohortExpression, options = CirceR::createGenerateOptions(generateStats = FALSE))    
    cohortDefinitionSet <- rbind(cohortDefinitionSet, data.frame(cohortId = as.numeric(cohortDefinitions[[i]]$cohortId),
                                                                 cohortName = cohortDefinitions[[i]]$cohortName, 
                                                                 sql = cohortSql,
                                                                 json = cohortJson,
                                                                 stringsAsFactors = FALSE))    
  }
  return(cohortDefinitionSet)
}
