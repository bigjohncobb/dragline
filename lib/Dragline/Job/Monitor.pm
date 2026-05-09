package Dragline::Job::Monitor;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Data::UUID;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "Monitor: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $target = $dbh->selectrow_hashref(
        q{SELECT canonical_name FROM targets WHERE id = ?},
        undef, $target_id,
    );
    die "Monitor: target $target_id not found" unless $target;

    my $run_id = $_uuid->create_str;

    # Insert the run record before the transaction so a failure still leaves a trace.
    $dbh->do(
        q{INSERT INTO monitor_runs (id, target_id, run_type, status)
          VALUES (?, ?, 'full', 'running')},
        undef, $run_id, $target_id,
    );

    my $has_deltas = 0;
    my $delta_count = 0;

    $dbh->begin_work;
    eval {
        # Find previous completed monitor run
        my $prev_run = $dbh->selectrow_hashref(
            q{SELECT id, started_at FROM monitor_runs
              WHERE target_id = ? AND status = 'complete'
              ORDER BY started_at DESC LIMIT 1},
            undef, $target_id,
        );

        my $since = $prev_run ? $prev_run->{started_at} : '1970-01-01';

        # Check for new raw_content
        my $new_content = $dbh->selectall_arrayref(
            q{SELECT id, source_type, source_url, content_hash
              FROM raw_content
              WHERE target_id = ? AND created_at > ?},
            { Slice => {} }, $target_id, $since,
        );

        for my $row (@$new_content) {
            my $delta_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO monitor_deltas
                    (id, monitor_run_id, target_id, delta_type, source_type, source_id, description, severity)
                  VALUES (?, ?, ?, 'new_content', 'raw_content', ?, ?, 'info')},
                undef, $delta_id, $run_id, $target_id,
                $row->{id},
                "New $row->{source_type} content: $row->{source_url}",
            );
            $has_deltas = 1;
            $delta_count++;
        }

        # Check for new forge_items
        my $new_forge = $dbh->selectall_arrayref(
            q{SELECT id, forge_item_id, title, url
              FROM forge_items
              WHERE target_id = ? AND imported_at > ?},
            { Slice => {} }, $target_id, $since,
        );

        for my $row (@$new_forge) {
            my $delta_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO monitor_deltas
                    (id, monitor_run_id, target_id, delta_type, source_type, source_id, description, severity)
                  VALUES (?, ?, ?, 'new_forge_item', 'forge_item', ?, ?, 'info')},
                undef, $delta_id, $run_id, $target_id,
                $row->{id},
                "New forge item: $row->{title}",
            );
            $has_deltas = 1;
            $delta_count++;
        }

        # Check for updated dossier sections since last monitor run
        my $updated_sections = $dbh->selectall_arrayref(
            q{SELECT ds.id, ds.section_number, ds.section_name
              FROM dossier_sections ds
              JOIN dossiers d ON d.id = ds.dossier_id
              WHERE d.target_id = ? AND ds.updated_at > ?},
            { Slice => {} }, $target_id, $since,
        );

        for my $row (@$updated_sections) {
            my $delta_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO monitor_deltas
                    (id, monitor_run_id, target_id, delta_type, source_type, source_id, description, severity)
                  VALUES (?, ?, ?, 'updated_dossier', 'dossier_section', ?, ?, 'low')},
                undef, $delta_id, $run_id, $target_id,
                $row->{id},
                "Updated dossier section $row->{section_number}: $row->{section_name}",
            );
            $has_deltas = 1;
            $delta_count++;
        }

        # Mark run as complete
        $dbh->do(
            q{UPDATE monitor_runs SET status='complete', completed_at=datetime('now')
              WHERE id=?},
            undef, $run_id,
        );

        $dbh->commit;

        # Trigger re-synthesis if deltas found
        if ($has_deltas && $delta_count >= ($args->{min_deltas} // 1)) {
            $self->app->minion->enqueue('synthesise',
                [{ target_id => $target_id }],
                { priority => 4 }
            );
            $log->info("Monitor: $delta_count deltas for target $target_id, queued synthesise");
        }
        else {
            $log->info("Monitor: $delta_count deltas for target $target_id, no action");
        }
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback; };
        eval {
            $dbh->do(
                q{UPDATE monitor_runs SET status='failed', completed_at=datetime('now') WHERE id=?},
                undef, $run_id,
            );
        };
        $log->error("Monitor: failed for target $target_id: $err");
        die $err;
    };
}

1;
