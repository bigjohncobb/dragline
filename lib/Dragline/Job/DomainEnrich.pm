package Dragline::Job::DomainEnrich;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Net::DNS;
use Net::Whois::Raw;
use Data::UUID;
use JSON::PP qw(encode_json);

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "DomainEnrich: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $domains = $dbh->selectall_arrayref(
        q{SELECT domain FROM target_domains WHERE target_id = ?},
        { Slice => {} }, $target_id,
    );

    unless (@$domains) {
        $log->info("DomainEnrich: no domains for target $target_id");
        return;
    }

    my $resolver = Net::DNS::Resolver->new;

    for my $d (@$domains) {
        my $domain = $d->{domain};
        next unless defined $domain && length $domain;

        eval {
            # --- DNS ---
            my @records;
            for my $type (qw(A MX NS TXT)) {
                my $packet = $resolver->query($domain, $type);
                next unless $packet;
                for my $rr ($packet->answer) {
                    my $value;
                    if ($type eq 'MX') {
                        $value = $rr->exchange . ' ' . $rr->preference;
                    } elsif ($type eq 'TXT') {
                        $value = $rr->txtdata;
                    } else {
                        $value = $rr->rdatastr;
                    }
                    push @records, {
                        type => $type,
                        value => $value,
                        ttl => $rr->ttl,
                    };
                }
            }

            $dbh->begin_work;

            # Insert DNS records with upsert to avoid race-condition duplicates
            for my $rec (@records) {
                my $id = $_uuid->create_str;
                $dbh->do(
                    q{INSERT INTO domain_dns_records (id, domain, target_id, record_type, record_value, ttl, fetched_at, created_at)
                      VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                      ON CONFLICT(domain, target_id, record_type, record_value) DO UPDATE SET
                        ttl = excluded.ttl,
                        fetched_at = datetime('now')},
                    undef,
                    $id, $domain, $target_id, $rec->{type}, $rec->{value}, $rec->{ttl},
                );
            }

            # --- WHOIS ---
            # alarm(15) is per-process; safe because Minion workers are forked
            # (one worker process per job), so alarms from concurrent jobs never interfere.
            my $raw_whois = eval {
                local $SIG{ALRM} = sub { die "WHOIS timeout\n" };
                alarm 15;
                my $r = Net::Whois::Raw::whois($domain);
                alarm 0;
                $r;
            };
            my $parsed = _parse_whois($raw_whois // '');

            my $whois_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO domain_whois (id, domain, target_id, registrar, registrant_name, registrant_org, created_date, updated_date, expiry_date, name_servers, raw_json, fetched_at, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                  ON CONFLICT(domain, target_id) DO UPDATE SET
                    registrar = excluded.registrar,
                    registrant_name = excluded.registrant_name,
                    registrant_org = excluded.registrant_org,
                    created_date = excluded.created_date,
                    updated_date = excluded.updated_date,
                    expiry_date = excluded.expiry_date,
                    name_servers = excluded.name_servers,
                    raw_json = excluded.raw_json,
                    fetched_at = datetime('now')},
                undef,
                $whois_id, $domain, $target_id,
                $parsed->{registrar},
                $parsed->{registrant_name},
                $parsed->{registrant_org},
                $parsed->{created_date},
                $parsed->{updated_date},
                $parsed->{expiry_date},
                $parsed->{name_servers},
                encode_json($parsed),
            );

            $dbh->commit;
            $log->info("DomainEnrich: enriched $domain for target $target_id");
        };

        if ($@) {
            eval { $dbh->rollback };
            $log->error("DomainEnrich: failed for domain $domain (target $target_id): $@");
        }
    }
}

sub _parse_whois {
    my ($raw) = @_;
    my %data;
    my @ns;

    for my $line (split /\n/, $raw) {
        next unless $line =~ /^\s*([^:]+)\s*:\s*(\S.*)/;
        my ($key, $val) = ($1, $2);
        $key =~ s/^\s+|\s+$//g;
        $val =~ s/^\s+|\s+$//g;
        next unless length $val;

        my $k = lc $key;
        if ($k =~ /registrar/) {
            $data{registrar} = $val unless $data{registrar};
        }
        elsif ($k =~ /registrant\s*name|registrant\s*organization/) {
            $data{registrant_name} = $val unless $data{registrant_name};
        }
        elsif ($k =~ /registrant\s*org/) {
            $data{registrant_org} = $val unless $data{registrant_org};
        }
        elsif ($k =~ /creation\s*date|created\s*date|created\s*on/) {
            $data{created_date} = $val unless $data{created_date};
        }
        elsif ($k =~ /updated\s*date|last\s*updated|modified\s*date/) {
            $data{updated_date} = $val unless $data{updated_date};
        }
        elsif ($k =~ /expir(y|ation)\s*date|registry\s*expiry|expires\s*on/) {
            $data{expiry_date} = $val unless $data{expiry_date};
        }
        elsif ($k =~ /name\s*server|nserver/) {
            push @ns, $val;
        }
    }
    $data{name_servers} = join(', ', @ns) if @ns;
    return \%data;
}

1;
