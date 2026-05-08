package Dragline::Job::Steps;
use strict;
use warnings;
use utf8;

use JSON::PP qw(encode_json decode_json);
use Data::UUID;

my $_uuid = Data::UUID->new;

sub is_done {
    my ($dbh, $scope_type, $scope_id, $step_name) = @_;
    my $row = $dbh->selectrow_arrayref(
        q{SELECT 1 FROM job_steps
          WHERE scope_type = ? AND scope_id = ? AND step_name = ?},
        undef, $scope_type, $scope_id, $step_name,
    );
    return $row ? 1 : '';
}

sub save {
    my ($dbh, $scope_type, $scope_id, $step_name, $data_ref) = @_;
    my $json = defined $data_ref ? encode_json($data_ref) : undef;
    my $id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO job_steps (id, scope_type, scope_id, step_name, result_json)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(scope_type, scope_id, step_name) DO UPDATE SET
            result_json = excluded.result_json},
        undef, $id, $scope_type, $scope_id, $step_name, $json,
    );
    return;
}

sub get {
    my ($dbh, $scope_type, $scope_id, $step_name) = @_;
    my $row = $dbh->selectrow_hashref(
        q{SELECT result_json FROM job_steps
          WHERE scope_type = ? AND scope_id = ? AND step_name = ?},
        undef, $scope_type, $scope_id, $step_name,
    );
    return undef unless $row && defined $row->{result_json};
    return decode_json($row->{result_json});
}

sub mark_done {
    my ($dbh, $scope_type, $scope_id, $step_name) = @_;
    return save($dbh, $scope_type, $scope_id, $step_name, undef);
}

sub clear {
    my ($dbh, $scope_type, $scope_id) = @_;
    $dbh->do(
        q{DELETE FROM job_steps WHERE scope_type = ? AND scope_id = ?},
        undef, $scope_type, $scope_id,
    );
    return;
}

1;
