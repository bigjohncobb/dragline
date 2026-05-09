package Dragline::Job::Backup;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Data::UUID;
use Digest::SHA qw(hmac_sha256 hmac_sha256_hex sha256_hex);
use POSIX qw(strftime);

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

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

    my $endpoint = $settings_getter->('backup_s3_endpoint') // '';
    my $bucket   = $settings_getter->('backup_s3_bucket')   // '';
    my $access   = $settings_getter->('backup_s3_access_key') // '';
    my $secret   = $settings_getter->('backup_s3_secret_key') // '';

    unless ($endpoint && $bucket && $access && $secret) {
        $log->error("Backup: S3 settings incomplete");
        return;
    }

    my $backup_id = $_uuid->create_str;
    my $db_path   = $ENV{DRAGLINE_DB} // './dragline.db';
    my $tmp_path  = "/tmp/dragline_backup_${backup_id}.db";

    $dbh->do(
        q{INSERT INTO backup_logs (id, backup_type, status, started_at)
          VALUES (?, 'full', 'running', datetime('now'))},
        undef, $backup_id,
    );

    eval {
        # Create snapshot via VACUUM INTO
        $dbh->do("VACUUM INTO ?", undef, $tmp_path);
        my $size = -s $tmp_path;
        my $checksum = _file_sha256($tmp_path);

        my $date = strftime('%Y%m%d_%H%M%S', gmtime());
        my $key  = "dragline_backup_${date}.db";

        _s3_upload($endpoint, $bucket, $access, $secret, $key, $tmp_path);

        $dbh->do(
            q{UPDATE backup_logs
              SET status='complete', file_path=?, file_size_bytes=?,
                  checksum=?, completed_at=datetime('now')
              WHERE id=?},
            undef, $key, $size, $checksum, $backup_id,
        );

        $log->info("Backup: uploaded $key to S3 ($size bytes)");
    };
    if ($@) {
        my $err = $@;
        eval {
            $dbh->do(
                q{UPDATE backup_logs
                  SET status='failed', error_message=?, completed_at=datetime('now')
                  WHERE id=?},
                undef, $err, $backup_id,
            );
        };
        $log->error("Backup failed: $err");
    }

    unlink $tmp_path if -e $tmp_path;

    # Clean up old backups per retention policy
    my $retention = $dbh->selectrow_array(
        q{SELECT value FROM settings WHERE key='backup_retention_days'},
        undef,
    ) // 30;
    $retention = 30 unless $retention =~ /^\d+$/;
    my $old = $dbh->selectall_arrayref(
        q{SELECT id, file_path FROM backup_logs
          WHERE status='complete'
            AND started_at < datetime('now', ? || ' days')},
        { Slice => {} }, -$retention,
    );
    for my $rec (@$old) {
        eval { _s3_delete($endpoint, $bucket, $access, $secret, $rec->{file_path}) };
        $dbh->do(q{DELETE FROM backup_logs WHERE id=?}, undef, $rec->{id});
    }
}

sub _file_sha256 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    my $sha = Digest::SHA->new(256);
    while (read($fh, my $buf, 65536)) {
        $sha->add($buf);
    }
    close $fh;
    return $sha->hexdigest;
}

sub _s3_upload {
    my ($endpoint, $bucket, $access, $secret, $key, $file_path) = @_;

    my $host = $endpoint;
    $host =~ s{^https?://}{};
    my $url = "$endpoint/$bucket/$key";

    my $date    = strftime('%Y%m%dT%H%M%SZ', gmtime());
    my $date_d  = substr($date, 0, 8);
    my $region  = 'us-east-1';

    # Sign with UNSIGNED-PAYLOAD to stream the file without loading it into memory.
    # AWS S3 accepts this when the request uses HTTPS and the bucket policy allows it.
    # Non-AWS S3-compatible stores may require PayloadSigningEnabled=false or equivalent.
    my $payload_hash = 'UNSIGNED-PAYLOAD';

    my %headers = (
        'host'                 => $host,
        'x-amz-content-sha256' => $payload_hash,
        'x-amz-date'           => $date,
    );

    my $canonical_headers = join('', map { lc($_) . ":$headers{$_}\n" } sort keys %headers) . "\n";
    my $signed_headers    = join(';', sort keys %headers);

    my $canonical_request = "PUT\n/$bucket/$key\n\n$canonical_headers\n$signed_headers\n$payload_hash";
    my $credential_scope  = "$date_d/$region/s3/aws4_request";
    my $string_to_sign    = "AWS4-HMAC-SHA256\n$date\n$credential_scope\n" . sha256_hex($canonical_request);

    my $k_date    = hmac_sha256($date_d, 'AWS4' . $secret);
    my $k_region  = hmac_sha256($region, $k_date);
    my $k_service = hmac_sha256('s3', $k_region);
    my $k_signing = hmac_sha256('aws4_request', $k_service);
    my $signature = hmac_sha256_hex($string_to_sign, $k_signing);

    my $auth = "AWS4-HMAC-SHA256 Credential=$access/$credential_scope,SignedHeaders=$signed_headers,Signature=$signature";

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(60);
    $ua->request_timeout(300);

    # Stream file directly without loading into memory
    my $asset = Mojo::Asset::File->new(path => $file_path);
    my $tx = $ua->put($url => {
        'Host'                 => $host,
        'X-Amz-Content-SHA256' => $payload_hash,
        'X-Amz-Date'           => $date,
        'Authorization'        => $auth,
        'Content-Length'       => $asset->size,
    } => $asset);

    my $res = $tx->result;
    unless ($res->is_success) {
        die "S3 upload failed: " . $res->code . " " . $res->body;
    }
}

sub _s3_delete {
    my ($endpoint, $bucket, $access, $secret, $key) = @_;

    my $host = $endpoint;
    $host =~ s{^https?://}{};
    my $url = "$endpoint/$bucket/$key";

    my $date    = strftime('%Y%m%dT%H%M%SZ', gmtime());
    my $date_d  = substr($date, 0, 8);
    my $region  = 'us-east-1';
    my $payload_hash = sha256_hex('');

    my %headers = (
        'host'                 => $host,
        'x-amz-content-sha256' => $payload_hash,
        'x-amz-date'           => $date,
    );

    my $canonical_headers = join('', map { lc($_) . ":$headers{$_}\n" } sort keys %headers) . "\n";
    my $signed_headers    = join(';', sort keys %headers);

    my $canonical_request = "DELETE\n/$bucket/$key\n\n$canonical_headers\n$signed_headers\n$payload_hash";
    my $credential_scope  = "$date_d/$region/s3/aws4_request";
    my $string_to_sign    = "AWS4-HMAC-SHA256\n$date\n$credential_scope\n" . sha256_hex($canonical_request);

    my $k_date    = hmac_sha256($date_d, 'AWS4' . $secret);
    my $k_region  = hmac_sha256($region, $k_date);
    my $k_service = hmac_sha256('s3', $k_region);
    my $k_signing = hmac_sha256('aws4_request', $k_service);
    my $signature = hmac_sha256_hex($string_to_sign, $k_signing);

    my $auth = "AWS4-HMAC-SHA256 Credential=$access/$credential_scope,SignedHeaders=$signed_headers,Signature=$signature";

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(30);
    $ua->request_timeout(60);

    my $tx = $ua->delete($url => {
        'Host'                 => $host,
        'X-Amz-Content-SHA256' => $payload_hash,
        'X-Amz-Date'           => $date,
        'Authorization'        => $auth,
    });

    my $res = $tx->result;
    unless ($res->is_success || $res->code == 204) {
        die "S3 delete failed: " . $res->code . " " . $res->body;
    }
}

1;
