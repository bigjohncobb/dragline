package Dragline::Job::Discover;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::Brave;
use Data::UUID;
use Mojo::UserAgent;

my $_uuid = Data::UUID->new;

# Singleton HTTP client to prevent connection pool and socket churn
my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(30);
        $ua->request_timeout(60);
        $ua;
    };
}

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "Discover: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $target = $dbh->selectrow_hashref(
        q{SELECT id, canonical_name, country FROM targets WHERE id=?},
        undef, $target_id,
    );
    die "Discover: target $target_id not found" unless $target;

    my $alias_rows = $dbh->selectall_arrayref(
        q{SELECT alias FROM target_aliases WHERE target_id=?},
        { Slice => {} }, $target_id,
    );
    $target->{aliases} = [map { $_->{alias} } @$alias_rows];

    my $brave_api_key = do {
        my $row = $dbh->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key='brave_api_key'},
            undef,
        );
        ($row && defined $row->{value} && $row->{value} ne '')
            ? ($row->{is_encrypted}
                ? $self->app->decrypt_value($row->{value})
                : $row->{value})
            : '';
    };

    my $ua = _ua();

    my $results = Dragline::Brave::search_for_target($ua, $brave_api_key, $target);

    my $queued_count = 0;
    for my $result (@$results) {
        my $url = $result->{url} // '';
        next unless length $url;

        my $in_queue = $dbh->selectrow_array(
            q{SELECT id FROM crawl_queue WHERE target_id=? AND url=?},
            undef, $target_id, $url,
        );
        next if $in_queue;

        my $in_content = $dbh->selectrow_array(
            q{SELECT id FROM raw_content WHERE target_id=? AND source_url=?},
            undef, $target_id, $url,
        );
        next if $in_content;

        my $cq_id = $_uuid->create_str;
        eval {
            $dbh->do(
                q{INSERT INTO crawl_queue (id, target_id, url, source, priority, status)
                  VALUES (?, ?, ?, 'brave_discovery', 3, 'pending')},
                undef, $cq_id, $target_id, $url,
            );
        };
        if ($@) {
            next if $@ =~ /UNIQUE constraint failed/i;
            die $@;
        }

        $self->app->minion->enqueue(
            crawl_static => [{target_id => $target_id, url => $url, crawl_queue_id => $cq_id}],
            {attempts => 3},
        );
        $queued_count++;
    }

    my $ce_id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO change_events
            (id, target_id, event_type, summary, severity)
          VALUES (?, ?, 'discovery_complete', ?, 'info')},
        undef, $ce_id, $target_id,
        "$queued_count URLs queued for crawl via Brave discovery",
    );

    $dbh->do(
        q{UPDATE target_monitoring SET last_discover_at=datetime('now') WHERE target_id=?},
        undef, $target_id,
    );

    $log->info("Discover: target $target_id — $queued_count URLs queued");
}

1;
