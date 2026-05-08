package Dragline::Job::IngestPDF;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::Crawl;
use Data::UUID;
use Digest::SHA qw(sha256_hex);
use Path::Tiny;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id  = $args->{target_id}  or die "IngestPDF: target_id required";
    my $file_path  = $args->{file_path}  or die "IngestPDF: file_path required";
    my $filename   = $args->{filename}   or die "IngestPDF: filename required";
    my $source_url = $args->{source_url};

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $file_bytes = eval { path($file_path)->slurp_raw };
    if ($@) {
        die "IngestPDF: cannot read $file_path: $@";
    }

    my $crawl_service_url = $dbh->selectrow_array(
        q{SELECT value FROM settings WHERE key='crawl_service_url'},
        undef,
    ) // '';
    unless (length $crawl_service_url) {
        die "IngestPDF: Crawl service URL not configured";
    }

    my ($text, $tables_json, $error) =
        Dragline::Crawl::extract_pdf_via_service($crawl_service_url, $file_bytes, $filename);

    if ($error) {
        unlink $file_path;
        die "IngestPDF: $error";
    }

    my $word_count   = scalar split(' ', $text // '');
    my $content_hash = sha256_hex($text // '');

    my $existing = $dbh->selectrow_array(
        q{SELECT id FROM raw_content WHERE target_id=? AND content_hash=?},
        undef, $target_id, $content_hash,
    );
    if ($existing) {
        $log->info("IngestPDF: Duplicate PDF, skipping: $filename");
        unlink $file_path;
        return;
    }

    my $rc_id = $_uuid->create_str;
    my $ce_id = $_uuid->create_str;

    eval {
        $dbh->begin_work;
        $dbh->do(
            q{INSERT INTO raw_content
                (id, target_id, source_type, source_url, source_title,
                 content_text, content_hash, word_count, fetched_at)
              VALUES (?, ?, 'pdf', ?, ?, ?, ?, ?, datetime('now'))},
            undef,
            $rc_id, $target_id, $source_url, $filename, $text, $content_hash, $word_count,
        );
        $dbh->do(
            q{INSERT INTO change_events
                (id, target_id, event_type, summary, raw_content_id, severity)
              VALUES (?, ?, 'new_content', ?, ?, 'info')},
            undef,
            $ce_id, $target_id, "New PDF ingested: $filename", $rc_id,
        );
        $dbh->commit;
    };
    if ($@) {
        eval { $dbh->rollback };
        unlink $file_path;
        die "IngestPDF: database error: $@";
    }

    unlink $file_path;

    # Mark existing dossier as stale if currently current
    eval {
        $dbh->do(
            q{UPDATE dossiers SET status='stale', updated_at=datetime('now')
              WHERE target_id=? AND status='current'},
            undef, $target_id,
        );
    };

    $self->app->minion->enqueue(embed => [{raw_content_id => $rc_id}], {attempts => 3});

    $log->info("IngestPDF: $filename → $rc_id ($word_count words)");
}

1;
