library(plumber)

port <- as.integer(Sys.getenv("NER_PORT", "3003"))

pr("ner_service.R") |> pr_run(host = "0.0.0.0", port = port)
