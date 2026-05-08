package Dragline::Embed;
use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Encode      qw(encode_utf8);
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);
use Dragline::Cost;
use Dragline::SSRF;

our $VERSION = '0.1.0';

# LRU cache with bounded size to prevent unbounded memory growth
my %EMBED_CACHE;
my @EMBED_CACHE_ORDER;
my $MAX_CACHE_SIZE = 1000;

my $DASHSCOPE_EMBED_URL = 'https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings';

# Singleton HTTP clients to prevent connection pool and socket churn
my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(30);
        $ua->request_timeout(60);
        $ua;
    };
}

sub _cache_key { sha256_hex(encode_utf8($_[0])) }

sub _cache_get {
    my ($key) = @_;
    return undef unless exists $EMBED_CACHE{$key};
    # Promote to most-recently-used
    @EMBED_CACHE_ORDER = grep { $_ ne $key } @EMBED_CACHE_ORDER;
    push @EMBED_CACHE_ORDER, $key;
    return $EMBED_CACHE{$key};
}

sub _cache_set {
    my ($key, $value) = @_;
    if (exists $EMBED_CACHE{$key}) {
        @EMBED_CACHE_ORDER = grep { $_ ne $key } @EMBED_CACHE_ORDER;
    } elsif (@EMBED_CACHE_ORDER >= $MAX_CACHE_SIZE) {
        my $oldest = shift @EMBED_CACHE_ORDER;
        delete $EMBED_CACHE{$oldest};
    }
    $EMBED_CACHE{$key} = $value;
    push @EMBED_CACHE_ORDER, $key;
}

sub embed {
    my ($dbh, $settings_getter, $text) = @_;

    my $key = _cache_key($text);
    my $cached = _cache_get($key);
    return $cached if defined $cached;

    my $ua = _ua();

    if ($ENV{DRAGLINE_AIRGAP}) {
        return _embed_ollama($ua, $settings_getter, $text, $key);
    }

    my $api_key = $settings_getter->('alibaba_api_key') or do {
        warn "Embed: no alibaba_api_key configured\n";
        return undef;
    };

    my ($ok, $reason) = Dragline::SSRF::validate($DASHSCOPE_EMBED_URL);
    unless ($ok) {
        warn "Embed: SSRF blocked DashScope URL: $reason\n";
        return undef;
    }

    my $body = encode_json({
        model           => 'text-embedding-v4',
        input           => [$text],
        dimension       => 1024,
        encoding_format => 'float',
    });

    my @delays   = (1, 3, 7);
    my $embedding;

    ATTEMPT: for my $attempt (0 .. scalar(@delays)) {
        sleep($delays[$attempt - 1]) if $attempt > 0;

        my $tx = $ua->post($DASHSCOPE_EMBED_URL =>
            {
                'Authorization' => "Bearer $api_key",
                'content-type'  => 'application/json',
            } => $body
        );

        my $res = $tx->result;
        if ($res->is_success) {
            my $data = decode_json($res->body);
            $embedding = $data->{data}[0]{embedding};

            my $tokens = $data->{usage}{total_tokens} // 0;
            Dragline::Cost::record($dbh,
                provider      => 'alibaba',
                operation     => 'embed',
                model         => 'text-embedding-v4',
                input_tokens  => $tokens,
                output_tokens => 0,
                cost_usd      => 0,
            );

            last ATTEMPT;
        }

        warn sprintf("Embed: DashScope attempt %d failed: %s\n", $attempt + 1, $res->code);
    }

    return undef unless defined $embedding;

    _cache_set($key, $embedding);
    return $embedding;
}

sub embed_batch {
    my ($dbh, $settings_getter, $texts) = @_;

    my @keys    = map { _cache_key($_) } @$texts;
    my @results = map { _cache_get($_) } @keys;

    my @uncached = grep { !defined $results[$_] } 0 .. $#$texts;
    return \@results unless @uncached;

    my $ua = _ua();

    if ($ENV{DRAGLINE_AIRGAP}) {
        for my $i (@uncached) {
            $results[$i] = _embed_ollama($ua, $settings_getter, $texts->[$i], $keys[$i]);
        }
        return \@results;
    }

    my $api_key = $settings_getter->('alibaba_api_key') or do {
        warn "Embed: no alibaba_api_key configured\n";
        return \@results;
    };

    my ($ok, $reason) = Dragline::SSRF::validate($DASHSCOPE_EMBED_URL);
    unless ($ok) {
        warn "Embed: SSRF blocked DashScope URL: $reason\n";
        return \@results;
    }

    my @texts_to_fetch = map { $texts->[$_] } @uncached;

    my $body = encode_json({
        model           => 'text-embedding-v4',
        input           => \@texts_to_fetch,
        dimension       => 1024,
        encoding_format => 'float',
    });

    my $tx = $ua->post($DASHSCOPE_EMBED_URL =>
        {
            'Authorization' => "Bearer $api_key",
            'content-type'  => 'application/json',
        } => $body
    );

    my $res = $tx->result;
    unless ($res->is_success) {
        warn "Embed: DashScope batch error " . $res->code . ": " . $res->body . "\n";
        return \@results;
    }

    my $data       = decode_json($res->body);
    my $embeddings = $data->{data} // [];

    for my $j (0 .. $#uncached) {
        my $i   = $uncached[$j];
        my $emb = $embeddings->[$j]{embedding};
        $results[$i] = $emb;
        _cache_set($keys[$i], $emb);
    }

    my $tokens = $data->{usage}{total_tokens} // 0;
    Dragline::Cost::record($dbh,
        provider      => 'alibaba',
        operation     => 'embed',
        model         => 'text-embedding-v4',
        input_tokens  => $tokens,
        output_tokens => 0,
        cost_usd      => 0,
    );

    return \@results;
}

sub _embed_ollama {
    my ($ua, $settings_getter, $text, $key) = @_;

    my $base_url = $settings_getter->('ollama_base_url') // 'http://localhost:11434';
    my $url      = "$base_url/api/embeddings";

    my ($ok, $reason) = Dragline::SSRF::validate($url);
    unless ($ok) {
        warn "Embed: SSRF blocked Ollama URL: $reason\n";
        return undef;
    }

    my $body = encode_json({ model => 'nomic-embed-text', prompt => $text });

    my $tx = $ua->post($url =>
        { 'content-type' => 'application/json' } => $body
    );

    my $res = $tx->result;
    unless ($res->is_success) {
        warn "Embed: Ollama error " . $res->code . ": " . $res->body . "\n";
        return undef;
    }

    my $data      = decode_json($res->body);
    my $embedding = $data->{embedding};
    _cache_set($key, $embedding) if defined $embedding;

    return $embedding;
}

1;
