package Dragline::Job::Score;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

# TODO: When R service is available, replace heuristic with POST to
# {r_service_url}/score with {text, source_type, word_count}.
# Expect response {tier: integer 1-163}.

my %TIER = (
    forge        => 30,
    crawl_static => 40,
    bucket_js    => 40,
    pdf          => 70,
    upload       => 60,
);

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $raw_content_id = $args->{raw_content_id}
        or die "Score: raw_content_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    $log->info("Score: R service not yet available. Applying heuristic significance_tier"
        . " for raw_content $raw_content_id.");

    my $row = $dbh->selectrow_hashref(
        q{SELECT source_type FROM raw_content WHERE id=?},
        undef, $raw_content_id,
    );
    unless ($row) {
        $log->warn("Score: raw_content $raw_content_id not found, skipping");
        return;
    }

    my $tier = $TIER{ $row->{source_type} } // 40;

    $dbh->do(
        q{UPDATE raw_content SET significance_tier=? WHERE id=?},
        undef, $tier, $raw_content_id,
    );

    $log->info("Score: $raw_content_id → tier $tier (source_type=$row->{source_type})");
}

1;
