package Dragline::Crypto;
use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256 sha256_hex hmac_sha256_hex);
use Crypt::AuthEnc::GCM;
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);

our $VERSION = '0.1.0';

sub _derive_key {
    my ($secret) = @_;
    return sha256($secret);
}

sub encrypt {
    my ($plaintext, $secret) = @_;

    my $key = _derive_key($secret);
    my $iv  = random_bytes(12);

    my $gcm = Crypt::AuthEnc::GCM->new('AES', $key);
    $gcm->iv_add($iv);

    my $ciphertext = $gcm->encrypt_add($plaintext);
    my $tag        = $gcm->encrypt_done;

    # tag is 16 bytes by default in CryptX GCM
    # Pad/truncate tag to exactly 16 bytes
    $tag = substr($tag . "\x00" x 16, 0, 16);

    return encode_base64($iv . $tag . $ciphertext, '');
}

sub decrypt {
    my ($ciphertext_b64, $secret) = @_;

    my $raw = decode_base64($ciphertext_b64);

    die "Decryption failed\n" unless length($raw) >= 28; # 12 IV + 16 tag minimum

    my $iv         = substr($raw, 0, 12);
    my $tag        = substr($raw, 12, 16);
    my $ciphertext = substr($raw, 28);

    my $key = _derive_key($secret);

    my $gcm = Crypt::AuthEnc::GCM->new('AES', $key);
    $gcm->iv_add($iv);

    my $plaintext = $gcm->decrypt_add($ciphertext);
    my $ok        = $gcm->decrypt_done($tag);

    die "Decryption failed\n" unless $ok;

    return $plaintext;
}

sub hmac_sign {
    my ($data, $secret) = @_;
    return hmac_sha256_hex($data, $secret);
}

sub hmac_verify {
    my ($data, $signature, $secret) = @_;
    my $expected = hmac_sign($data, $secret);

    # Constant-time comparison
    return 0 unless length($signature) == length($expected);

    my $diff = 0;
    for my $i (0 .. length($expected) - 1) {
        $diff |= ord(substr($signature, $i, 1)) ^ ord(substr($expected, $i, 1));
    }
    return $diff == 0 ? 1 : 0;
}

1;
