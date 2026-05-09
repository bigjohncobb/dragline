install.packages(c("plumber", "reticulate", "jsonlite", "logger"), repos = "https://cloud.r-project.org")

library(reticulate)

if (!reticulate::condaenv_exists("ner_env")) {
    reticulate::install_miniconda()
    reticulate::conda_create("ner_env", python_version = "3.10")
}

reticulate::conda_install(
    envname  = "ner_env",
    packages = c("torch", "transformers", "langdetect", "sentencepiece", "protobuf"),
    pip      = TRUE
)

cat("NER service dependencies installed successfully.\n")
cat("Start the service with: Rscript r_service/run.R\n")
