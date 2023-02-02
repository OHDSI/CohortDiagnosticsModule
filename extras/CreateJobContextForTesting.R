# Create a job context for testing purposes

library(Strategus)
library(dplyr)
source("SettingsFunctions.R")

# Generic Helpers ----------------------------
getModuleInfo <- function() {
  checkmate::assert_file_exists("MetaData.json")
  return(ParallelLogger::loadSettingsFromJson("MetaData.json"))
}

# Sample Data Helpers ----------------------------
getSampleCohortDefintionSet <- function() {
  sampleCohorts <- CohortGenerator::createEmptyCohortDefinitionSet()
  cohortJsonFiles <- list.files(path = system.file("testdata/name/cohorts", package = "CohortGenerator"), full.names = TRUE)
  for (i in 1:length(cohortJsonFiles)) {
    cohortJsonFileName <- cohortJsonFiles[i]
    cohortName <- tools::file_path_sans_ext(basename(cohortJsonFileName))
    cohortJson <- readChar(cohortJsonFileName, file.info(cohortJsonFileName)$size)
    sampleCohorts <- rbind(sampleCohorts, data.frame(cohortId = i,
                                                     cohortName = cohortName,
                                                     cohortDefinition = cohortJson,
                                                     stringsAsFactors = FALSE))
  }
  sampleCohorts <- apply(sampleCohorts,1,as.list)
  return(sampleCohorts)
}

createCohortSharedResource <- function(cohortDefinitionSet) {
  sharedResource <- list(cohortDefinitions = cohortDefinitionSet)
  class(sharedResource) <- c("CohortDefinitionSharedResources", "SharedResources")
  return(sharedResource)
}

cohortDefinitionSet <- getSampleCohortDefintionSet()
cohortDefinitionIds <- as.integer(unlist(lapply(cohortDefinitionSet, function (x) {x$cohortId})))
analysisSpecifications <- createEmptyAnalysisSpecificiations() %>%
  addSharedResources(createCohortSharedResource(cohortDefinitionSet)) %>%
  addModuleSpecifications(createCohortDiagnosticsModuleSpecifications(
    cohortIds = cohortDefinitionIds,
    runInclusionStatistics = FALSE, # Disable since this requires CG to create the cohort tables
    runIncludedSourceConcepts = TRUE,
    runOrphanConcepts = TRUE,
    runTimeSeries = FALSE,
    runVisitContext = TRUE,
    runBreakdownIndexEvents = TRUE,
    runIncidenceRate = TRUE,
    runCohortRelationship = TRUE,
    runTemporalCohortCharacterization = TRUE,
    incremental = FALSE
  )
)

# Module Settings Spec ----------------------------
executionSettings <- Strategus::createCdmExecutionSettings(connectionDetailsReference = "dummy",
                                                           workDatabaseSchema = "main",
                                                           cdmDatabaseSchema = "main",
                                                           cohortTableNames = CohortGenerator::getCohortTableNames(cohortTable = "cohort"),
                                                           workFolder = "dummy",
                                                           resultsFolder = "dummy",
                                                           minCellCount = 5)

# Job Context ----------------------------
module <- "CohortDiagnosticsModule"
moduleIndex <- 1
moduleExecutionSettings <- executionSettings
moduleExecutionSettings$workSubFolder <- "dummy"
moduleExecutionSettings$resultsSubFolder <- "dummy"
moduleExecutionSettings$databaseId <- 123
jobContext <- list(sharedResources = analysisSpecifications$sharedResources,
                   settings = analysisSpecifications$moduleSpecifications[[moduleIndex]]$settings,
                   moduleExecutionSettings = moduleExecutionSettings)
saveRDS(jobContext, "tests/testJobContext.rds")

