library(plumber)
library(reticulate)
library(jsonlite)
library(logger)

MODEL_NAME <- "Babelscape/wikineural-multilingual-ner"

# Activate the conda environment and load the pipeline once at startup.
tryCatch({
    use_condaenv("ner_env", required = TRUE)
    transformers <- import("transformers")
    ner_pipeline <- transformers$pipeline(
        "ner",
        model                = MODEL_NAME,
        aggregation_strategy = "simple"
    )
    log_info("NER pipeline loaded: {MODEL_NAME}")
}, error = function(e) {
    log_error("Failed to load NER pipeline: {conditionMessage(e)}")
    stop(e)
})

# Split text into ~400-word chunks with 20-word overlap, respecting sentence
# boundaries so entities spanning a cut point are captured in at least one chunk.
chunk_text <- function(text, window = 400L, overlap = 20L) {
    words <- unlist(strsplit(text, "\\s+"))
    n     <- length(words)
    if (n <= window) return(list(text))

    chunks <- list()
    start  <- 1L
    while (start <= n) {
        end  <- min(start + window - 1L, n)
        seg  <- paste(words[start:end], collapse = " ")

        # Walk back to the last sentence boundary if not at the end of input.
        if (end < n && grepl("[.!?]", seg)) {
            last_boundary <- regexpr(".*[.!?]", seg)
            if (last_boundary > 0L) {
                seg <- substr(seg, 1L, last_boundary + attr(last_boundary, "match.length") - 1L)
            }
        }

        chunks  <- c(chunks, list(seg))
        start   <- end - overlap + 1L
        if (start >= n) break
    }
    chunks
}

# Deduplicate entities: for each (word, entity_group) pair keep the max score.
dedup_entities <- function(entities) {
    if (length(entities) == 0L) return(list())
    key  <- paste(sapply(entities, `[[`, "word"),
                  sapply(entities, `[[`, "entity_group"), sep = "\x1f")
    best <- tapply(seq_along(entities), key, function(idx) {
        scores <- sapply(entities[idx], function(e) e[["score"]])
        idx[which.max(scores)]
    })
    entities[unname(unlist(best))]
}

#* @post /ner
#* @serializer unboxedJSON
function(req) {
    body <- tryCatch(
        fromJSON(req$postBody, simplifyVector = FALSE),
        error = function(e) NULL
    )

    if (is.null(body) || !nzchar(body[["text"]])) {
        return(list(entities = list(), error = "Missing or empty 'text' field"))
    }

    text   <- body[["text"]]
    chunks <- chunk_text(text)
    raw    <- list()

    for (chunk in chunks) {
        result <- tryCatch(
            ner_pipeline(chunk),
            error = function(e) {
                log_warn("NER pipeline error on chunk: {conditionMessage(e)}")
                list()
            }
        )
        raw <- c(raw, result)
    }

    deduped <- dedup_entities(raw)

    entities <- lapply(deduped, function(e) {
        list(
            word        = e[["word"]],
            entity_type = e[["entity_group"]],
            score       = round(e[["score"]], 4L)
        )
    })

    list(entities = entities)
}

#* @get /health
#* @serializer unboxedJSON
function() {
    list(status = "ok", model = MODEL_NAME)
}
