package Dragline::Job::NerExtract;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Mojo::UserAgent;
use JSON::PP qw(encode_json decode_json);
use Data::UUID;

my $_uuid = Data::UUID->new;
my $_ua   = Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 120);

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $raw_content_id = $args->{raw_content_id}
        or die "NerExtract: raw_content_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $content = $dbh->selectrow_hashref(
        q{SELECT content_text FROM raw_content WHERE id=?},
        undef, $raw_content_id,
    );
    unless ($content) {
        die "NerExtract: raw_content $raw_content_id not found";
    }

    my $text = $content->{content_text} // '';
    unless (length $text) {
        $log->info("NerExtract: empty text for $raw_content_id, skipping");
        return;
    }

    my $already = $dbh->selectrow_array(
        q{SELECT COUNT(*) FROM ner_entities WHERE raw_content_id=?},
        undef, $raw_content_id,
    );
    if ($already) {
        $log->info("NerExtract: already processed $raw_content_id, skipping");
        return;
    }

    my $svc_url = _get_setting($dbh, $self->app, 'r_service_url');
    unless ($svc_url) {
        $log->warn("NerExtract: r_service_url not configured, skipping");
        return;
    }

    my $endpoint = "$svc_url/ner";
    my $tx = $_ua->post($endpoint, {'Content-Type' => 'application/json'},
        encode_json({ text => $text }));

    my $code = $tx->result->code;
    unless ($tx->result->is_success) {
        # Die so Minion can retry; skip only if the service explicitly rejects the input (4xx).
        if ($code >= 500) {
            die "NerExtract: service returned $code for $raw_content_id";
        }
        $log->warn("NerExtract: service returned $code for $raw_content_id, skipping");
        return;
    }

    my $parsed = eval { decode_json($tx->result->body) };
    if ($@ || !$parsed) {
        die "NerExtract: JSON parse failed for $raw_content_id: $@";
    }

    if ($parsed->{error}) {
        $log->warn("NerExtract: service error for $raw_content_id: $parsed->{error}");
        return;
    }

    my $entities = $parsed->{entities} // [];
    unless (@$entities) {
        $log->info("NerExtract: no entities found for $raw_content_id");
        return;
    }

    $dbh->begin_work;
    eval {
        for my $e (@$entities) {
            my $word = $e->{word} or next;
            my $type = $e->{entity_type} or next;
            next unless $type =~ /^(?:PER|ORG|LOC|MISC)$/;
            $dbh->do(
                q{INSERT OR IGNORE INTO ner_entities
                    (id, raw_content_id, entity_text, entity_type, confidence, model_used, created_at)
                  VALUES (?, ?, ?, ?, ?, 'wikineural-multilingual-ner', datetime('now'))},
                undef,
                $_uuid->create_str, $raw_content_id, $word, $type, $e->{score},
            );
        }
        $dbh->commit;
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback };
        die "NerExtract: DB insert failed for $raw_content_id: $err";
    };

    $log->info("NerExtract: stored " . scalar(@$entities) . " entities for $raw_content_id");
}

sub _get_setting {
    my ($dbh, $app, $key) = @_;
    my $row = $dbh->selectrow_hashref(
        q{SELECT value, is_encrypted FROM settings WHERE key=?},
        undef, $key,
    );
    return undef unless $row && defined $row->{value} && $row->{value} ne '';
    return $row->{is_encrypted}
        ? $app->decrypt_value($row->{value})
        : $row->{value};
}

1;
