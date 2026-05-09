package Dragline::Job::SanctionsScreen;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Mojo::UserAgent;
use JSON::PP qw(encode_json decode_json);
use Data::UUID;

my $_uuid = Data::UUID->new;

# Singleton HTTP client
my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(30);
        $ua->request_timeout(60);
        $ua;
    };
}

sub _trim_entity {
    my ($entity) = @_;
    return encode_json({
        id       => $entity->{id},
        caption  => $entity->{caption},
        schema   => $entity->{schema},
        datasets => $entity->{datasets},
        url      => $entity->{properties}{sourceUrl}[0] // $entity->{properties}{wikipediaUrl}[0],
    });
}

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "SanctionsScreen: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    if ($self->app->airgap_mode) {
        $log->info("SanctionsScreen: skipped in airgap mode");
        return;
    }

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

    my $api_key = $settings_getter->('opensanctions_api_key');
    unless ($api_key) {
        $log->info("SanctionsScreen: no opensanctions_api_key configured");
        return;
    }

    my $target = $dbh->selectrow_hashref(
        q{SELECT canonical_name FROM targets WHERE id = ?},
        undef, $target_id,
    );
    die "SanctionsScreen: target $target_id not found" unless $target;

    my @queries;
    push @queries, $target->{canonical_name};

    my $aliases = $dbh->selectall_arrayref(
        q{SELECT alias FROM target_aliases WHERE target_id = ?},
        undef, $target_id,
    );
    for my $a (@$aliases) {
        push @queries, $a->[0];
    }

    my $ua = _ua();
    my $inserted = 0;

    for my $query (@queries) {
        next unless defined $query && length $query;

        my $url = Mojo::URL->new('https://api.opensanctions.org/search');
        $url->query(q => $query);

        my $tx = $ua->get($url => {
            Authorization => "ApiKey $api_key",
            Accept        => 'application/json',
        });

        if (my $err = $tx->error) {
            $log->warn("SanctionsScreen: API error for '$query': $err->{message}");
            next;
        }

        my $res = $tx->result;
        if ($res->code == 429) {
            my $retry_after = $res->headers->header('Retry-After') // 60;
            $log->warn("SanctionsScreen: rate limited, sleeping ${retry_after}s");
            sleep($retry_after);
            next;
        }
        unless ($res->code == 200) {
            $log->warn("SanctionsScreen: HTTP " . $res->code . " for '$query'");
            next;
        }

        my $data = eval { decode_json($res->body) };
        unless ($data) {
            $log->warn("SanctionsScreen: JSON parse failed for '$query'");
            next;
        }

        my $results = $data->{results} // [];
        for my $r (@$results) {
            my $score = $r->{score} // 0;
            next unless $score >= ($args->{min_score} // 0.5);

            my $entity = $r->{entity} // {};
            my $matched = $entity->{caption} // $query;
            my $dataset = join(', ', @{$entity->{datasets} // []});

            my $id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO sanctions_matches
                    (id, target_id, person_id, match_type, entity_name, matched_name, dataset, score, match_data, status)
                  VALUES (?, ?, NULL, 'target', ?, ?, ?, ?, ?, 'pending')
                  ON CONFLICT DO NOTHING},
                undef,
                $id, $target_id,
                $query,
                $matched,
                $dataset,
                $score,
                _trim_entity($entity),
            );
            $inserted++;
        }
    }

    # Also screen people associated with target
    my $people = $dbh->selectall_arrayref(
        q{SELECT p.id, p.canonical_name
          FROM people p
          JOIN person_roles pr ON pr.person_id = p.id
          WHERE pr.target_id = ?},
        { Slice => {} }, $target_id,
    );

    for my $person (@$people) {
        next unless defined $person->{canonical_name} && length $person->{canonical_name};

        my $url = Mojo::URL->new('https://api.opensanctions.org/search');
        $url->query(q => $person->{canonical_name});

        my $tx = $ua->get($url => {
            Authorization => "ApiKey $api_key",
            Accept        => 'application/json',
        });

        if (my $err = $tx->error) {
            $log->warn("SanctionsScreen: API error for person '$person->{canonical_name}': $err->{message}");
            next;
        }

        my $res = $tx->result;
        if ($res->code == 429) {
            my $retry_after = $res->headers->header('Retry-After') // 60;
            $log->warn("SanctionsScreen: rate limited, sleeping ${retry_after}s");
            sleep($retry_after);
            next;
        }
        unless ($res->code == 200) {
            $log->warn("SanctionsScreen: HTTP " . $res->code . " for person '$person->{canonical_name}'");
            next;
        }

        my $data = eval { decode_json($res->body) };
        unless ($data) {
            $log->warn("SanctionsScreen: JSON parse failed for person '$person->{canonical_name}'");
            next;
        }

        my $results = $data->{results} // [];
        for my $r (@$results) {
            my $score = $r->{score} // 0;
            next unless $score >= ($args->{min_score} // 0.5);

            my $entity = $r->{entity} // {};
            my $matched = $entity->{caption} // $person->{canonical_name};
            my $dataset = join(', ', @{$entity->{datasets} // []});

            my $id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO sanctions_matches
                    (id, target_id, person_id, match_type, entity_name, matched_name, dataset, score, match_data, status)
                  VALUES (?, ?, ?, 'person', ?, ?, ?, ?, ?, 'pending')
                  ON CONFLICT DO NOTHING},
                undef,
                $id, $target_id, $person->{id},
                $person->{canonical_name},
                $matched,
                $dataset,
                $score,
                _trim_entity($entity),
            );
            $inserted++;
        }
    }

    $log->info("SanctionsScreen: inserted $inserted matches for target $target_id");
}

1;
