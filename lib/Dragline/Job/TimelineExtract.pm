package Dragline::Job::TimelineExtract;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Data::UUID;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "TimelineExtract: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $target = $dbh->selectrow_hashref(
        q{SELECT canonical_name FROM targets WHERE id = ?},
        undef, $target_id,
    );
    die "TimelineExtract: target $target_id not found" unless $target;

    my $section = $dbh->selectrow_hashref(
        q{SELECT ds.id, ds.content, d.id AS dossier_id
          FROM dossier_sections ds
          JOIN dossiers d ON d.id = ds.dossier_id
          WHERE d.target_id = ? AND d.status = 'current'
            AND ds.section_number = 6},
        undef, $target_id,
    );

    unless ($section && defined $section->{content} && length $section->{content}) {
        $log->info("TimelineExtract: no section 6 for target $target_id");
        return;
    }

    my @events = _parse_events($section->{content});

    my $inserted = 0;
    for my $evt (@events) {
        my $id = $_uuid->create_str;
        $dbh->do(
            q{INSERT INTO event_timeline
                (id, target_id, event_date, event_type, description, source_section, confidence)
              VALUES (?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT DO NOTHING},
            undef,
            $id, $target_id,
            $evt->{event_date},
            $evt->{event_type} // 'general',
            $evt->{description},
            'Section 6: Event Timeline',
            $evt->{confidence} // 'medium',
        );
        $inserted++;
    }

    $log->info("TimelineExtract: inserted $inserted events for target $target_id");
}

sub _parse_events {
    my ($text) = @_;
    my @events;

    my @lines = split /\n/, $text;
    for my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;

        # Try to match date patterns: YYYY-MM-DD, DD/MM/YYYY, Month YYYY, etc.
        my ($date, $desc);
        if ($line =~ m{^(\d{4}-\d{2}-\d{2})\s*[-:]\s*(.+)$}) {
            $date = $1;
            $desc = $2;
        }
        elsif ($line =~ m{^(\d{1,2}/\d{1,2}/\d{4})\s*[-:]\s*(.+)$}) {
            my ($d, $m, $y) = split m{/}, $1;
            $date = sprintf('%04d-%02d-%02d', $y, $m, $d);
            $desc = $2;
        }
        elsif ($line =~ m{^([A-Za-z]+\s+\d{4})\s*[-:]\s*(.+)$}) {
            $date = _month_year_to_date($1);
            $desc = $2;
        }
        elsif ($line =~ m{^(\d{4})\s*[-:]\s*(.+)$}) {
            $date = "$1-01-01";
            $desc = $2;
        }

        next unless defined $desc && length $desc;

        my $type = _infer_type($desc);

        push @events, {
            event_date  => $date,
            description => $desc,
            event_type  => $type,
            confidence  => (defined $date ? 'medium' : 'low'),
        };
    }

    return @events;
}

sub _month_year_to_date {
    my ($my) = @_;
    my %months = (
        january => 1, february => 2, march => 3, april => 4,
        may => 5, june => 6, july => 7, august => 8,
        september => 9, october => 10, november => 11, december => 12,
    );
    if ($my =~ m{^([A-Za-z]+)\s+(\d{4})$}) {
        my $m = lc $1;
        my $y = $2;
        my $n = $months{$m} // 1;
        return sprintf('%04d-%02d-01', $y, $n);
    }
    return undef;
}

sub _infer_type {
    my ($desc) = @_;
    my $d = lc $desc;
    return 'sanctions'     if $d =~ /sanction/;
    return 'regulatory'    if $d =~ /regulat|investigation|enforcement|fine|penalty/;
    return 'legal'         if $d =~ /lawsuit|litigation|court|trial|verdict|settlement/;
    return 'financial'     if $d =~ /merger|acquisition|ipo|funding|investment|revenue|profit|loss|earnings/;
    return 'personnel'     if $d =~ /appointed|resigned|ceo|director|executive|board|hired|fired/;
    return 'corporate'     if $d =~ /founded|established|incorporated|rebranded|restructured/;
    return 'media'         if $d =~ /reported|published|article|coverage|press|media/;
    return 'general';
}

1;
