package Dragline::Brave;
use strict;
use warnings;
use utf8;

use Mojo::URL;

our $VERSION = '0.1.0';

sub search {
    my ($ua, $api_key, $query, $count) = @_;
    $count //= 20;

    unless ($api_key) {
        return ([], 'Brave API key not configured');
    }

    my $url = Mojo::URL->new('https://api.search.brave.com/res/v1/web/search');
    $url->query(q => $query, count => $count);

    my $tx = $ua->get($url->to_string, {'X-Subscription-Token' => $api_key});

    if (my $err = $tx->error) {
        return ([], $err->{message} // 'Search request failed');
    }

    my $data = $tx->res->json;
    unless ($data && ref $data->{web} eq 'HASH' && ref $data->{web}{results} eq 'ARRAY') {
        return ([], undef);
    }

    my @results = map {
        {
            url         => $_->{url},
            title       => $_->{title},
            description => $_->{description},
        }
    } @{$data->{web}{results}};

    return (\@results, undef);
}

sub search_for_target {
    my ($ua, $api_key, $target) = @_;

    if (!$api_key || $ENV{DRAGLINE_AIRGAP}) {
        warn "Brave search skipped (airgap or no key)\n";
        return [];
    }

    my $name    = $target->{canonical_name} // '';
    my $country = $target->{country} // '';
    my @aliases = @{$target->{aliases} // []};

    my @queries;
    push @queries, $name;
    push @queries, "$name $country" if $country;
    push @queries, qq{"$name" "annual report"};
    push @queries, qq{"$name" "regulatory filing"};
    for my $alias (@aliases) {
        push @queries, $alias;
        last if @queries >= 5;
    }

    my %seen_url;
    my @all_results;

    for my $query (@queries) {
        my ($results, $err) = search($ua, $api_key, $query, 20);
        next if $err || !@$results;
        for my $r (@$results) {
            next if $seen_url{$r->{url}}++;
            push @all_results, $r;
        }
    }

    return \@all_results;
}

1;
