package Dragline::Job::GapDetect;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Data::UUID;

my $_uuid = Data::UUID->new;

my @GAP_CHECKS = (
    {
        type        => 'content_silence',
        sql         => q{SELECT MAX(created_at) FROM raw_content WHERE target_id = ?},
        thresholds  => { low => 14, medium => 30, high => 60 },
        min_age     => 28,
    },
    {
        type        => 'media_silence',
        sql         => q{SELECT MAX(published_at) FROM forge_items WHERE target_id = ?},
        thresholds  => { low => 30, medium => 60, high => 90 },
        min_age     => 60,
    },
    {
        type        => 'website_freeze',
        sql         => q{SELECT MAX(created_at) FROM raw_content WHERE target_id = ? AND source_type IN ('crawl_static','bucket_js')},
        thresholds  => { low => 30, medium => 60, high => 90 },
        min_age     => 60,
    },
    {
        type        => 'financial_silence',
        sql         => q{SELECT MAX(created_at) FROM raw_content WHERE target_id = ? AND source_type = 'pdf'},
        thresholds  => { low => 45, medium => 90, high => 180 },
        min_age     => 90,
    },
    {
        type        => 'personnel_silence',
        sql         => q{SELECT MAX(created_at) FROM person_roles WHERE target_id = ?},
        thresholds  => { low => 90, medium => 180, high => 365 },
        min_age     => 180,
    },
);

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "GapDetect: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $target = $dbh->selectrow_hashref(
        q{SELECT canonical_name, created_at FROM targets WHERE id = ?},
        undef, $target_id,
    );
    die "GapDetect: target $target_id not found" unless $target;

    my $target_age_days = $dbh->selectrow_array(
        q{SELECT CAST(julianday('now') - julianday(?) AS INTEGER)},
        undef, $target->{created_at},
    );

    $dbh->begin_work;
    eval {
        for my $check (@GAP_CHECKS) {
            if ($target_age_days < $check->{min_age}) {
                $log->debug("GapDetect: skipping $check->{type} for target $target_id (age $target_age_days < $check->{min_age})");
                next;
            }

            my $last_seen_at = $dbh->selectrow_array($check->{sql}, undef, $target_id);

            my $gap_days;
            if (defined $last_seen_at) {
                $gap_days = $dbh->selectrow_array(
                    q{SELECT CAST(julianday('now') - julianday(?) AS INTEGER)},
                    undef, $last_seen_at,
                );
            }
            else {
                $gap_days = $target_age_days;
            }

            my $severity = _severity($gap_days, $check->{thresholds});

            my $existing = $dbh->selectrow_hashref(
                q{SELECT id, gap_days, severity, is_active FROM gap_signals
                  WHERE target_id = ? AND gap_type = ?},
                undef, $target_id, $check->{type},
            );

            if (defined $severity) {
                # Gap is active
                if (!$existing) {
                    # New gap
                    my $id = $_uuid->create_str;
                    $dbh->do(
                        q{INSERT INTO gap_signals
                            (id, target_id, gap_type, gap_days, severity, is_active, first_detected_at)
                          VALUES (?, ?, ?, ?, ?, 1, datetime('now'))},
                        undef, $id, $target_id, $check->{type}, $gap_days, $severity,
                    );
                    _emit_change_event($dbh, $target_id, $check->{type}, $severity,
                        "$check->{type} gap of $gap_days days detected for $target->{canonical_name}");
                }
                elsif ($existing->{is_active}) {
                    if (_severity_rank($severity) > _severity_rank($existing->{severity})) {
                        # Escalation
                        $dbh->do(
                            q{UPDATE gap_signals SET gap_days = ?, severity = ?
                              WHERE id = ?},
                            undef, $gap_days, $severity, $existing->{id},
                        );
                        _emit_change_event($dbh, $target_id, $check->{type}, $severity,
                            "$check->{type} gap escalated to $severity ($gap_days days) for $target->{canonical_name}");
                    }
                    else {
                        # Same or lower severity — just update gap_days
                        $dbh->do(
                            q{UPDATE gap_signals SET gap_days = ? WHERE id = ?},
                            undef, $gap_days, $existing->{id},
                        );
                    }
                }
                else {
                    # Re-open previously resolved gap
                    $dbh->do(
                        q{UPDATE gap_signals SET
                            is_active = 1, resolved_at = NULL,
                            first_detected_at = COALESCE(first_detected_at, datetime('now')),
                            gap_days = ?, severity = ?
                          WHERE id = ?},
                        undef, $gap_days, $severity, $existing->{id},
                    );
                    _emit_change_event($dbh, $target_id, $check->{type}, $severity,
                        "$check->{type} gap re-opened ($gap_days days) for $target->{canonical_name}");
                }
            }
            else {
                # Gap is not active
                if ($existing && $existing->{is_active}) {
                    $dbh->do(
                        q{UPDATE gap_signals SET is_active = 0, resolved_at = datetime('now')
                          WHERE id = ?},
                        undef, $existing->{id},
                    );
                    _emit_change_event($dbh, $target_id, $check->{type}, 'info',
                        "$check->{type} gap resolved for $target->{canonical_name}");
                }
            }
        }

        $dbh->commit;
        $log->info("GapDetect: completed for target $target_id");
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback; };
        $log->error("GapDetect: failed for target $target_id: $err");
        die $err;
    };
}

sub _severity {
    my ($gap_days, $thresholds) = @_;
    return 'high'   if $gap_days >= $thresholds->{high};
    return 'medium' if $gap_days >= $thresholds->{medium};
    return 'low'    if $gap_days >= $thresholds->{low};
    return undef;
}

sub _severity_rank {
    my ($severity) = @_;
    return 3 if $severity eq 'high';
    return 2 if $severity eq 'medium';
    return 1 if $severity eq 'low';
    return 0;
}

sub _emit_change_event {
    my ($dbh, $target_id, $gap_type, $severity, $summary) = @_;
    my $id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO change_events
            (id, target_id, event_type, summary, severity)
          VALUES (?, ?, 'gap_detected', ?, ?)},
        undef, $id, $target_id, $summary, $severity,
    );
}

1;
