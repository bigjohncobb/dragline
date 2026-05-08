package Dragline::Job::CrawlStatic;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::SSRF;
use Dragline::Crawl;
use Data::UUID;
use Digest::SHA qw(sha256_hex);
use URI;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id      = $args->{target_id}     or die "CrawlStatic: target_id required";
    my $url            = $args->{url}            or die "CrawlStatic: url required";
    my $crawl_queue_id = $args->{crawl_queue_id};

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    if ($crawl_queue_id) {
        $dbh->do(
            q{UPDATE crawl_queue SET status='processing' WHERE id=?},
            undef, $crawl_queue_id,
        );
    }

    my ($ssrf_ok, $ssrf_reason) = Dragline::SSRF::validate($url);
    unless ($ssrf_ok) {
        _fail_queue($dbh, $crawl_queue_id, "SSRF blocked: $ssrf_reason");
        _insert_change_event($dbh, $target_id, 'crawl_failed', 'low',
            "Crawl failed: SSRF blocked: $ssrf_reason", $url);
        die "SSRF blocked: $ssrf_reason";
    }

    # Check domain blocklist
    my $blocked = _check_domain_blocklist($dbh, $url);
    if ($blocked) {
        _fail_queue($dbh, $crawl_queue_id, "Domain blocked: $blocked");
        _insert_change_event($dbh, $target_id, 'crawl_failed', 'low',
            "Crawl failed: domain blocked ($blocked)", $url);
        die "Domain blocked: $blocked";
    }

    my ($text, $title, $final_url, $word_count, $error) = Dragline::Crawl::fetch_static($url);

    if ($error) {
        _fail_queue($dbh, $crawl_queue_id, $error);
        _insert_change_event($dbh, $target_id, 'crawl_failed', 'low',
            "Crawl failed: $error", $url);
        die $error;
    }

    my $threshold = $dbh->selectrow_array(
        q{SELECT value FROM settings WHERE key='crawl_content_threshold'},
        undef,
    ) // 500;

    if ($word_count < $threshold) {
        $log->info("URL $url may need JS rendering, consider CrawlJS job");
    }

    my $content_hash = sha256_hex($text // '');

    # Check for exact duplicate by hash
    my $existing_hash_id = $dbh->selectrow_array(
        q{SELECT id FROM raw_content WHERE target_id=? AND content_hash=?},
        undef, $target_id, $content_hash,
    );
    if ($existing_hash_id) {
        if ($crawl_queue_id) {
            $dbh->do(
                q{UPDATE crawl_queue SET status='skipped', processed_at=datetime('now') WHERE id=?},
                undef, $crawl_queue_id,
            );
        }
        $log->info("Duplicate content, skipping: $url");
        return;
    }

    # Check for content change at same URL
    my $existing_by_url = $dbh->selectrow_hashref(
        q{SELECT id, content_hash, content_text, word_count FROM raw_content
          WHERE target_id=? AND source_url=? ORDER BY fetched_at DESC LIMIT 1},
        undef, $target_id, $final_url,
    );

    my $rc_id = $_uuid->create_str;
    my $ce_id = $_uuid->create_str;
    my $is_update = $existing_by_url ? 1 : 0;

    eval {
        $dbh->begin_work;
        $dbh->do(
            q{INSERT INTO raw_content
                (id, target_id, source_type, source_url, source_title,
                 content_text, content_hash, word_count, fetched_at)
              VALUES (?, ?, 'crawl_static', ?, ?, ?, ?, ?, datetime('now'))},
            undef,
            $rc_id, $target_id, $final_url, $title, $text, $content_hash, $word_count,
        );

        if ($is_update) {
            my $diff_id = $_uuid->create_str;
            my $diff_text = _compute_diff($existing_by_url->{content_text} // '', $text // '');
            my $word_delta = $word_count - ($existing_by_url->{word_count} // 0);
            $dbh->do(
                q{INSERT INTO raw_content_diffs
                    (id, target_id, old_raw_content_id, new_raw_content_id, source_url,
                     old_hash, new_hash, diff_text, word_count_delta)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)},
                undef,
                $diff_id, $target_id, $existing_by_url->{id}, $rc_id, $final_url,
                $existing_by_url->{content_hash}, $content_hash, $diff_text, $word_delta,
            );
            eval {
                $dbh->do(
                    q{INSERT INTO change_events
                        (id, target_id, event_type, summary, source_url, raw_content_id, severity)
                      VALUES (?, ?, 'updated_content', ?, ?, ?, 'low')},
                    undef,
                    $ce_id, $target_id, "Content updated at $final_url",
                    $final_url, $rc_id,
                );
            };
            if ($@) {
                # Fallback for databases without updated_content in CHECK constraint
                $dbh->do(
                    q{INSERT INTO change_events
                        (id, target_id, event_type, summary, source_url, raw_content_id, severity)
                      VALUES (?, ?, 'new_content', ?, ?, ?, 'info')},
                    undef,
                    $ce_id, $target_id, "Content updated at $final_url",
                    $final_url, $rc_id,
                );
            }
        }
        else {
            $dbh->do(
                q{INSERT INTO change_events
                    (id, target_id, event_type, summary, source_url, raw_content_id, severity)
                  VALUES (?, ?, 'new_content', ?, ?, ?, 'info')},
                undef,
                $ce_id, $target_id, "New content crawled from $final_url",
                $final_url, $rc_id,
            );
        }
        $dbh->commit;
    };
    if ($@) {
        eval { $dbh->rollback };
        die "CrawlStatic: database error: $@";
    }

    if ($crawl_queue_id) {
        $dbh->do(
            q{UPDATE crawl_queue SET status='complete', processed_at=datetime('now') WHERE id=?},
            undef, $crawl_queue_id,
        );
    }

    $dbh->do(
        q{UPDATE target_monitoring SET last_crawl_at=datetime('now') WHERE target_id=?},
        undef, $target_id,
    );

    # Mark existing dossier as stale if currently current
    eval {
        $dbh->do(
            q{UPDATE dossiers SET status='stale', updated_at=datetime('now')
              WHERE target_id=? AND status='current'},
            undef, $target_id,
        );
    };

    $self->app->minion->enqueue(embed => [{raw_content_id => $rc_id}], {attempts => 3});

    $log->info("CrawlStatic: $url → $rc_id ($word_count words)");
}

sub _fail_queue {
    my ($dbh, $crawl_queue_id, $error) = @_;
    return unless $crawl_queue_id;
    eval {
        $dbh->do(
            q{UPDATE crawl_queue SET status='failed', last_error=?,
              attempts=attempts+1 WHERE id=?},
            undef, $error, $crawl_queue_id,
        );
    };
}

sub _insert_change_event {
    my ($dbh, $target_id, $event_type, $severity, $summary, $source_url) = @_;
    my $id = $_uuid->create_str;
    eval {
        $dbh->do(
            q{INSERT INTO change_events
                (id, target_id, event_type, summary, source_url, severity)
              VALUES (?, ?, ?, ?, ?, ?)},
            undef, $id, $target_id, $event_type, $summary, $source_url, $severity,
        );
    };
}

sub _check_domain_blocklist {
    my ($dbh, $url) = @_;
    my $domain = eval {
        my $u = URI->new($url);
        $u->host;
    };
    return undef unless $domain;
    my $blocked = $dbh->selectrow_array(
        q{SELECT domain FROM domain_blocklist WHERE domain = ?},
        undef, $domain,
    );
    return $blocked;
}

sub _compute_diff {
    my ($old_text, $new_text) = @_;
    my @old_lines = split(/\n/, $old_text);
    my @new_lines = split(/\n/, $new_text);
    my $diff = '';
    my $max = scalar(@old_lines) > scalar(@new_lines) ? scalar(@old_lines) : scalar(@new_lines);
    for my $i (0..$max-1) {
        my $o = $i < @old_lines ? $old_lines[$i] : undef;
        my $n = $i < @new_lines ? $new_lines[$i] : undef;
        if (!defined $o && defined $n) {
            $diff .= "+ $n\n";
        }
        elsif (defined $o && !defined $n) {
            $diff .= "- $o\n";
        }
        elsif (defined $o && defined $n && $o ne $n) {
            $diff .= "- $o\n+ $n\n";
        }
    }
    $diff = '[no line-level differences]' unless length $diff;
    return $diff;
}

1;
