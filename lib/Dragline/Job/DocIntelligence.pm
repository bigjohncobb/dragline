package Dragline::Job::DocIntelligence;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::LLM;
use Data::UUID;
use JSON::PP qw(encode_json decode_json);

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $raw_content_id = $args->{raw_content_id} or die "DocIntelligence: raw_content_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $content = $dbh->selectrow_hashref(
        q{SELECT target_id, source_type, content_text FROM raw_content WHERE id = ?},
        undef, $raw_content_id,
    );
    unless ($content) {
        die "DocIntelligence: raw_content $raw_content_id not found";
    }

    my $text = $content->{content_text} // '';
    unless (length $text) {
        $log->info("DocIntelligence: empty text for raw_content $raw_content_id");
        return;
    }

    # Truncate to keep prompt size reasonable
    $text = _truncate_at_sentence($text, 4000);

    my $settings_getter = sub {
        my ($key) = @_;
        my $row = $dbh->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key=?},
            undef, $key,
        );
        return undef unless $row;
        return undef unless defined($row->{value}) && $row->{value} ne '';
        return $row->{is_encrypted}
            ? $self->app->decrypt_value($row->{value})
            : $row->{value};
    };

    my $sys = "You are a document intelligence engine. Analyse the provided text and return a single JSON object. "
        . "Do not include any prose before or after the JSON. The JSON must have these keys:\n\n"
        . "classification: a short label describing the document type (e.g. annual_report, press_release, legal_filing, contract, other)\n"
        . "entities: array of {name, type} objects for organisations, people, and places mentioned\n"
        . "dates: array of ISO dates (YYYY-MM-DD) explicitly mentioned\n"
        . "financial_figures: array of {figure, currency, context} objects\n"
        . "key_statements: array of up to 5 important verbatim quotes or paraphrased statements\n";

    my ($json_text, $provider, $tokens) = Dragline::LLM::complete(
        $dbh, $settings_getter,
        task_type     => 'doc_intelligence',
        system_prompt => $sys,
        user_prompt   => $text,
        max_tokens    => 2048,
        target_id     => $content->{target_id},
        job_id        => $self->id,
    );

    unless (defined $json_text && length $json_text) {
        $log->warn("DocIntelligence: LLM returned empty for raw_content $raw_content_id");
        return;
    }

    my $parsed = eval { decode_json($json_text) };
    my $status = $parsed ? 'complete' : 'failed';
    unless ($parsed) {
        $log->warn("DocIntelligence: JSON parse failed for raw_content $raw_content_id: $@");
        # Store raw text anyway so operator can inspect
        $parsed = { raw_response => $json_text };
    }

    my $ext_id = $_uuid->create_str;
    $dbh->begin_work;
    eval {
        $dbh->do(
            q{INSERT INTO document_extractions (id, raw_content_id, extraction_type, extracted_json, model_used, confidence, status, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))},
            undef,
            $ext_id, $raw_content_id, 'structured',
            encode_json($parsed),
            $provider // 'unknown',
            undef,
            $status,
        );
        $dbh->commit;
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback; };
        $log->error("DocIntelligence: DB insert failed for raw_content $raw_content_id: $err");
        die $err;
    };

    $log->info("DocIntelligence: extraction $status for raw_content $raw_content_id");
}

sub _truncate_at_sentence {
    my ($text, $word_limit) = @_;
    return $text unless length $text;
    my @words = split /\s+/, $text;
    return $text if @words <= $word_limit;
    my $truncated = join(' ', @words[0 .. $word_limit - 1]);
    # Walk back to last sentence boundary
    if ($truncated =~ /^(.*[.!?])(\s+\S+)?$/s) {
        return $1 . "\n\n[truncated]";
    }
    return $truncated . "\n\n[truncated]";
}

1;
