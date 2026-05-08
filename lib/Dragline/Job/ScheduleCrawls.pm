package Dragline::Job::ScheduleCrawls;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Data::UUID;

my $_uuid = Data::UUID->new;

my %CADENCE_OFFSET = (
    hourly  => '+1 hour',
    daily   => '+1 day',
    weekly  => '+7 days',
    monthly => '+30 days',
);

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $dbh    = $self->app->db_for_job;
    my $minion = $self->app->minion;
    my $log    = $self->app->log;

    my ($forge_count, $crawl_count, $discover_count) = (0, 0, 0);

    # ---- ForgeSync ----
    my $forge_targets = $dbh->selectall_arrayref(
        q{SELECT target_id, forge_sync_cadence FROM target_monitoring
          WHERE next_forge_sync_at <= datetime('now')
            AND forge_sync_cadence != 'disabled'},
        { Slice => {} },
    );
    for my $tm (@$forge_targets) {
        $minion->enqueue(
            forge_sync => [{target_id => $tm->{target_id}}],
            {attempts => 3},
        );
        my $offset = $CADENCE_OFFSET{ $tm->{forge_sync_cadence} } // '+1 day';
        $dbh->do(
            "UPDATE target_monitoring SET next_forge_sync_at = datetime('now', ?)"
            . " WHERE target_id = ?",
            undef, $offset, $tm->{target_id},
        );
        $forge_count++;
    }

    # ---- CrawlStatic ----
    my $crawl_targets = $dbh->selectall_arrayref(
        q{SELECT tm.target_id, tm.crawl_cadence, t.primary_domain
          FROM target_monitoring tm
          JOIN targets t ON t.id = tm.target_id
          WHERE tm.next_crawl_at <= datetime('now')
            AND tm.crawl_cadence != 'disabled'},
        { Slice => {} },
    );
    for my $tm (@$crawl_targets) {
        my @domains;
        push @domains, $tm->{primary_domain} if $tm->{primary_domain};

        my $extra = $dbh->selectcol_arrayref(
            q{SELECT domain FROM target_domains WHERE target_id=?},
            undef, $tm->{target_id},
        );
        push @domains, @$extra;

        my %seen_domain;
        for my $domain (grep { !$seen_domain{$_}++ } @domains) {
            my $url = "https://$domain/";

            my $existing_cq = $dbh->selectrow_array(
                q{SELECT id FROM crawl_queue
                  WHERE target_id=? AND url=? AND status='pending'},
                undef, $tm->{target_id}, $url,
            );

            my $cq_id;
            unless ($existing_cq) {
                $cq_id = $_uuid->create_str;
                eval {
                    $dbh->do(
                        q{INSERT INTO crawl_queue
                            (id, target_id, url, source, priority, status)
                          VALUES (?, ?, ?, 'manual', 5, 'pending')},
                        undef, $cq_id, $tm->{target_id}, $url,
                    );
                };
                if ($@) {
                    if ($@ =~ /UNIQUE constraint failed/i) {
                        $cq_id = $dbh->selectrow_array(
                            q{SELECT id FROM crawl_queue WHERE target_id=? AND url=?},
                            undef, $tm->{target_id}, $url,
                        );
                    } else {
                        $log->error("ScheduleCrawls: crawl_queue insert failed: $@");
                        next;
                    }
                }
            } else {
                $cq_id = $existing_cq;
            }

            $minion->enqueue(
                crawl_static => [{
                    target_id      => $tm->{target_id},
                    url            => $url,
                    crawl_queue_id => $cq_id,
                }],
                {attempts => 3},
            );
            $crawl_count++;
        }

        my $offset = $CADENCE_OFFSET{ $tm->{crawl_cadence} } // '+7 days';
        $dbh->do(
            "UPDATE target_monitoring SET next_crawl_at = datetime('now', ?)"
            . " WHERE target_id = ?",
            undef, $offset, $tm->{target_id},
        );
    }

    # ---- Discover ----
    my $discover_targets = $dbh->selectall_arrayref(
        q{SELECT target_id, discover_cadence FROM target_monitoring
          WHERE next_discover_at <= datetime('now')
            AND discover_cadence != 'disabled'},
        { Slice => {} },
    );
    for my $tm (@$discover_targets) {
        $minion->enqueue(
            discover => [{target_id => $tm->{target_id}}],
            {attempts => 3},
        );
        my $offset = $CADENCE_OFFSET{ $tm->{discover_cadence} } // '+7 days';
        $dbh->do(
            "UPDATE target_monitoring SET next_discover_at = datetime('now', ?)"
            . " WHERE target_id = ?",
            undef, $offset, $tm->{target_id},
        );
        $discover_count++;
    }

    $log->info("ScheduleCrawls: $forge_count forge syncs,"
        . " $crawl_count crawls, $discover_count discovers queued.");

    # Re-enqueue self for next hourly run, protected by minion lock to prevent duplicates
    if ($minion->lock('schedule_crawls_reenqueue', 3600)) {
        $minion->enqueue('schedule_crawls', [{}], {delay => 3600, attempts => 1});
        $minion->unlock('schedule_crawls_reenqueue');
    }
}

1;
