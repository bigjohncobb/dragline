package Dragline::Storage;
use strict;
use warnings;
use utf8;

use Mojo::UserAgent;
use Digest::SHA qw(hmac_sha256 hmac_sha256_hex sha256_hex);
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);

our $VERSION = '0.1.0';

# Returns a settings hashref if all four keys are configured, undef otherwise.
sub build_settings {
    my ($getter) = @_;
    my $endpoint   = $getter->('content_s3_endpoint')   // '';
    my $bucket     = $getter->('content_s3_bucket')     // '';
    my $access_key = $getter->('content_s3_access_key') // '';
    my $secret_key = $getter->('content_s3_secret_key') // '';
    return undef unless $endpoint && $bucket && $access_key && $secret_key;
    return {
        endpoint   => $endpoint,
        bucket     => $bucket,
        access_key => $access_key,
        secret_key => $secret_key,
    };
}

# Upload bytes to S3-compatible storage.
# Returns (1, undef) on success or (undef, $error_string) on failure.
sub upload_bytes {
    my ($settings, $key, $bytes, $content_type) = @_;
    $content_type //= 'text/plain; charset=utf-8';

    my $endpoint   = $settings->{endpoint};
    my $bucket     = $settings->{bucket};
    my $access_key = $settings->{access_key};
    my $secret_key = $settings->{secret_key};

    my $host = $endpoint;
    $host =~ s{^https?://}{};
    my $url = "$endpoint/$bucket/$key";

    my $date   = strftime('%Y%m%dT%H%M%SZ', gmtime());
    my $date_d = substr($date, 0, 8);
    my $region = 'us-east-1';

    my $payload_hash = sha256_hex($bytes);
    my $length       = length($bytes);

    my %hdrs = (
        'content-length'       => $length,
        'content-type'         => $content_type,
        'host'                 => $host,
        'x-amz-content-sha256' => $payload_hash,
        'x-amz-date'           => $date,
    );

    my $canonical_headers = join('', map { "$_:$hdrs{$_}\n" } sort keys %hdrs) . "\n";
    my $signed_headers    = join(';', sort keys %hdrs);

    my $canonical_request = "PUT\n/$bucket/$key\n\n$canonical_headers\n$signed_headers\n$payload_hash";
    my $credential_scope  = "$date_d/$region/s3/aws4_request";
    my $string_to_sign    = "AWS4-HMAC-SHA256\n$date\n$credential_scope\n" . sha256_hex($canonical_request);

    my $k_date    = hmac_sha256($date_d,       'AWS4' . $secret_key);
    my $k_region  = hmac_sha256($region,        $k_date);
    my $k_service = hmac_sha256('s3',           $k_region);
    my $k_signing = hmac_sha256('aws4_request', $k_service);
    my $signature = hmac_sha256_hex($string_to_sign, $k_signing);

    my $auth = "AWS4-HMAC-SHA256 Credential=$access_key/$credential_scope,"
             . "SignedHeaders=$signed_headers,Signature=$signature";

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(30);
    $ua->request_timeout(120);

    my $tx = $ua->put($url => {
        'Host'                 => $host,
        'Content-Type'         => $content_type,
        'Content-Length'       => $length,
        'X-Amz-Content-SHA256' => $payload_hash,
        'X-Amz-Date'           => $date,
        'Authorization'        => $auth,
    } => $bytes);

    if (my $err = $tx->error) {
        return (undef, $err->{message} // 'Upload failed');
    }
    unless ($tx->res->is_success) {
        return (undef, 'S3 upload HTTP ' . $tx->res->code . ': ' . $tx->res->body);
    }
    return (1, undef);
}

# Download object from S3-compatible storage.
# Returns ($bytes, undef) on success or (undef, $error_string) on failure.
sub download_bytes {
    my ($settings, $key) = @_;

    my $endpoint   = $settings->{endpoint};
    my $bucket     = $settings->{bucket};
    my $access_key = $settings->{access_key};
    my $secret_key = $settings->{secret_key};

    my $host = $endpoint;
    $host =~ s{^https?://}{};
    my $url = "$endpoint/$bucket/$key";

    my $date         = strftime('%Y%m%dT%H%M%SZ', gmtime());
    my $date_d       = substr($date, 0, 8);
    my $region       = 'us-east-1';
    my $payload_hash = sha256_hex('');

    my %hdrs = (
        'host'                 => $host,
        'x-amz-content-sha256' => $payload_hash,
        'x-amz-date'           => $date,
    );

    my $canonical_headers = join('', map { "$_:$hdrs{$_}\n" } sort keys %hdrs) . "\n";
    my $signed_headers    = join(';', sort keys %hdrs);

    my $canonical_request = "GET\n/$bucket/$key\n\n$canonical_headers\n$signed_headers\n$payload_hash";
    my $credential_scope  = "$date_d/$region/s3/aws4_request";
    my $string_to_sign    = "AWS4-HMAC-SHA256\n$date\n$credential_scope\n" . sha256_hex($canonical_request);

    my $k_date    = hmac_sha256($date_d,       'AWS4' . $secret_key);
    my $k_region  = hmac_sha256($region,        $k_date);
    my $k_service = hmac_sha256('s3',           $k_region);
    my $k_signing = hmac_sha256('aws4_request', $k_service);
    my $signature = hmac_sha256_hex($string_to_sign, $k_signing);

    my $auth = "AWS4-HMAC-SHA256 Credential=$access_key/$credential_scope,"
             . "SignedHeaders=$signed_headers,Signature=$signature";

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(30);
    $ua->request_timeout(120);

    my $tx = $ua->get($url => {
        'Host'                 => $host,
        'X-Amz-Content-SHA256' => $payload_hash,
        'X-Amz-Date'           => $date,
        'Authorization'        => $auth,
    });

    if (my $err = $tx->error) {
        return (undef, $err->{message} // 'Download failed');
    }
    unless ($tx->res->is_success) {
        return (undef, 'S3 download HTTP ' . $tx->res->code);
    }
    return ($tx->res->body, undef);
}

1;
