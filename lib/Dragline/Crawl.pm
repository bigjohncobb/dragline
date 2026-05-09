package Dragline::Crawl;
use strict;
use warnings;
use utf8;

use Mojo::UserAgent;
use Mojo::URL;
use Dragline::SSRF;

our $VERSION = '0.1.0';

# Singleton HTTP clients to prevent connection pool and socket churn
my $_ua_singleton;
my $_ua_long_timeout_singleton;

sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new(max_redirects => 5);
        $ua->connect_timeout(30);
        $ua->request_timeout(30);
        $ua->transactor->name('Mozilla/5.0 (compatible; Dragline/1.0; entity intelligence)');
        $ua;
    };
}

sub _ua_long {
    return $_ua_long_timeout_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->request_timeout(120);
        $ua;
    };
}

sub fetch_static {
    my ($url) = @_;

    my ($ok, $reason) = Dragline::SSRF::validate($url);
    unless ($ok) {
        return (undef, undef, $url, 0, "SSRF blocked: $reason");
    }

    my $ua = _ua();

    my $tx = $ua->get($url);

    if (my $err = $tx->error) {
        return (undef, undef, $url, 0, $err->{message} // 'Request failed');
    }

    unless ($tx->res->is_success) {
        return (undef, undef, $url, 0, 'HTTP ' . $tx->res->code . ': ' . $tx->res->message);
    }

    my $final_url = $tx->req->url->to_abs->to_string;
    my $body      = $tx->res->body;

    my $title = '';
    if ($body =~ m{<title[^>]*>(.*?)</title>}is) {
        $title = $1;
        $title =~ s/\s+/ /g;
        $title =~ s/^\s+|\s+$//g;
    }

    my $text = $body;
    $text =~ s{<script[^>]*>.*?</script>}{}gis;
    $text =~ s{<style[^>]*>.*?</style>}{}gis;
    $text =~ s/<[^>]+>//g;
    $text =~ s/&nbsp;/ /g;
    $text =~ s/&amp;/&/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#39;/'/g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;

    my $word_count = scalar split(' ', $text);

    return ($text, $title, $final_url, $word_count, undef);
}

sub is_js_heavy {
    my ($response) = @_;

    my $body = $response->body;

    if (length($body) < 2000) {
        my @scripts = ($body =~ /<script/gi);
        return 1 if @scripts >= 3;
    }

    for my $marker ('ng-app', 'data-reactroot', '__NEXT_DATA__', '__nuxt', 'data-v-app') {
        return 1 if index($body, $marker) >= 0;
    }

    return 0;
}

sub fetch_via_service {
    my ($crawl_service_url, $url) = @_;

    # Loopback is allowed for operator-configured crawl services
    unless ($crawl_service_url =~ m{^https?://(?:localhost|127\.0\.0\.1)(?::\d+)?(?:/|$)}i) {
        my ($ok, $reason) = Dragline::SSRF::validate($crawl_service_url);
        unless ($ok) {
            return (undef, undef, $url, 0, "SSRF blocked: $reason");
        }
    }

    my $ua = _ua_long();

    my $tx = $ua->post("$crawl_service_url/crawl" => json => {url => $url});

    if (my $err = $tx->error) {
        return (undef, undef, $url, 0, $err->{message} // 'Crawl service unavailable');
    }

    my $data = $tx->res->json // {};

    return (
        $data->{text},
        $data->{title},
        $data->{final_url} // $url,
        $data->{word_count} // 0,
        $data->{error},
    );
}

sub extract_pdf_via_service {
    my ($crawl_service_url, $file_bytes, $filename) = @_;

    my $ua = _ua_long();

    my $tx = $ua->post(
        "$crawl_service_url/extract" => form => {
            file => {
                content        => $file_bytes,
                filename       => $filename,
                'Content-Type' => 'application/octet-stream',
            },
        }
    );

    if (my $err = $tx->error) {
        return (undef, undef, $err->{message} // 'PDF extraction service unavailable');
    }

    my $data = $tx->res->json // {};

    return ($data->{text}, $data->{tables}, $data->{error});
}

1;
