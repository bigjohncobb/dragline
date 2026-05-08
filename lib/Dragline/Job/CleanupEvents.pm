package Dragline::Job::CleanupEvents;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    # Prune seen change events older than 30 days
    my $n = $dbh->do(
        q{DELETE FROM change_events
          WHERE seen=1 AND seen_at < datetime('now', '-30 days')},
        undef,
    );
    $n = ($n eq '0E0') ? 0 : $n;
    $log->info("CleanupEvents: deleted $n seen change events.");

    # Prune unseen change events older than 90 days to prevent unbounded growth
    my $n2 = $dbh->do(
        q{DELETE FROM change_events
          WHERE seen=0 AND created_at < datetime('now', '-90 days')},
        undef,
    );
    $n2 = ($n2 eq '0E0') ? 0 : $n2;
    $log->info("CleanupEvents: deleted $n2 unseen change events older than 90 days.");

    # Prune login_attempts older than 10 minutes to prevent table bloat
    my $n3 = $dbh->do(
        q{DELETE FROM login_attempts WHERE attempted_at < datetime('now', '-10 minutes')},
        undef,
    );
    $n3 = ($n3 eq '0E0') ? 0 : $n3;
    $log->info("CleanupEvents: deleted $n3 stale login attempts.");

    # Prune crawl_queue completed/skipped items older than 30 days, failed older than 7 days
    my $n4 = $dbh->do(
        q{DELETE FROM crawl_queue
          WHERE (status IN ('complete','skipped') AND processed_at < datetime('now', '-30 days'))
             OR (status = 'failed' AND processed_at < datetime('now', '-7 days'))},
        undef,
    );
    $n4 = ($n4 eq '0E0') ? 0 : $n4;
    $log->info("CleanupEvents: deleted $n4 stale crawl queue items.");

    # Prune cost_records older than 365 days
    my $n5 = $dbh->do(
        q{DELETE FROM cost_records WHERE created_at < datetime('now', '-365 days')},
        undef,
    );
    $n5 = ($n5 eq '0E0') ? 0 : $n5;
    $log->info("CleanupEvents: deleted $n5 stale cost records.");

    # Prune audit_log older than 365 days
    my $n6 = $dbh->do(
        q{DELETE FROM audit_log WHERE created_at < datetime('now', '-365 days')},
        undef,
    );
    $n6 = ($n6 eq '0E0') ? 0 : $n6;
    $log->info("CleanupEvents: deleted $n6 stale audit log entries.");
}

1;
